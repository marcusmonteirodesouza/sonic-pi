# This file is part of Sonic Pi: http://sonic-pi.net
# Full project source: https://github.com/samaaron/sonic-pi
# License: https://github.com/samaaron/sonic-pi/blob/master/LICENSE.md
#
# Copyright 2017 by Sam Aaron (http://sam.aaron.name).
# All rights reserved.
#
# Permission is granted for use, copying, modification, and
# distribution of modified versions of this work as long as this
# notice is included.
#++

require_relative "cueevent"

module SonicPi

  module EventMatcherUtil
    def safe_matcher_call(matcher, event)
      return true unless matcher
      begin
        return matcher.call(event)
      rescue Exception => e
        return false
      end
    end
  end

  class EventHistoryNode
    attr_accessor :children, :events

    def initialize
      @children = {}
      @events = []
    end
  end

  class EventMatcher
    include EventMatcherUtil

    def initialize(path, val_matcher=nil)
      path = String.new(path)
      path.strip!
      path[0] = '' if path.start_with?('/')
      path.gsub!(/\/\s*\*\*\s*\//, '/.*/')
      path.gsub!(/(?<!\.)\*/, '[^/]*')
      matcher_str = "\\A/?#{path}/?\\Z"
      @matcher = Regexp.new(matcher_str)
      @val_matcher = val_matcher
    end

    def match(path, val)
      @matcher.match(path) && safe_matcher_call(@val_matcher, val)
    end
  end


  class EventMatchers
    def initialize
      @matchers = []
    end

    def put(matcher_path, val_matcher, prom)
      matcher = EventMatcher.new(matcher_path, val_matcher)
      @matchers << [matcher, prom]
    end

    def match(path, val)
      @matchers.delete_if do |matcher, prom|
        if matcher.match(path, val)
          prom.deliver! true
          true
        else
          false
        end
      end
    end
  end



  class EventHistory
    include EventMatcherUtil

    def initialize
      @state = EventHistoryNode.new
      @event_matchers = EventMatchers.new
      @unprocessed = Queue.new
      @process_mut = Mutex.new
      @sync_notification_mut = Mutex.new
      @sync_notifiers = Hash.new([])
      @get_mut = Mutex.new
    end


    # Get the last seen version (at or before the current time)
    # Do not change time
    def get(t, p, i, d, b, path, val_matcher=nil, get_next=false)
      wait_for_threads
      res = nil
      get_event = CueEvent.new(t, p, i, d, b, path, [], {})

      @get_mut.synchronize do
        @unprocessed.size.times { __insert_event!(@unprocessed.pop) }
        res = get_w_no_mutex(get_event, val_matcher, get_next)
        return res
      end
    end

    # Get next version (after current time)
    # return nil if nothing found
    # Does not modify time
    def get_next(t, p, i, d, b, path, val_matcher=nil)
      get(t, p, i, d, b, path, val_matcher, true)
    end

    # Register cue event for time t
    # Do not modify time
    def set(t, p, i, d, b, path, val, meta={})
      # TODO = fill meta correctly with Thread Locals if available
      ce = CueEvent.new(t, p, i, d, b, path, val, meta)
      @unprocessed << ce
      @event_matchers.match(ce.path, ce.val)
    end

    # Get the next version (after the current time)
    # Set time to time of cue

    def sync(t, p, i, d, b, path, val_matcher=nil,timeout=nil, &blk)
      wait_for_threads
      prom = nil
      ge = CueEvent.new(t, p, i, d, b, path, [], {})
      @get_mut.synchronize do
        @unprocessed.size.times { __insert_event!(@unprocessed.pop) }
        res = get_w_no_mutex(ge, val_matcher, true)
        return res if res
        prom = Promise.new
        matcher = @event_matchers.put ge.path, val_matcher, prom
        blk.call(matcher) if blk
      end

      prom.get

      # have to do a get_next again in case
      # an event with an earlier timestamp arrived
      # after this one
      res = get_next(t, p, i, d, b, path, val_matcher)
      raise "sync error - couldn't find result for #{[t, i, p, d, b, path]}" unless res
      return res
      #TODO:  set thread locals
    end

    # Wait for the first out of the list of cues to arrive
    # Set time to time of first cue
    # Once first cue has arrived - no longer wait for other cues
    def sync_first(t, p, i, d, b, paths, val_matcher, timeout=nil)

    end

    # Wait for all cues to arrive (after the current time)
    # Set time to time of last cue
    def sync_all(t, p, i, d, b, paths, val_matcher, timeout=nil)

    end

    private
    def get_w_no_mutex(ge, val_matcher, get_next=false)
      # get value or return default
      if ge.path.start_with? '/'
        path = String.new(ge.path)
      else
        path = String.new("/#{path}")
      end

      # Remove multiple sequential ** matchers
      path.gsub!(/(\/\*\*)+/, '/**')
      split_path = path.split('/').drop(1).map do |segment|
        stripped = segment.strip
        if stripped == '**'
          stripped
        elsif matcher?(segment)
          Regexp.new(segment.gsub!('*', '.*'))
        else
          stripped
        end
      end

      return __get(ge, split_path, 0, val_matcher, @state, nil, get_next)
    end

    def __get(ge, split_path, idx, val_matcher, sn, res = nil, get_next)
      if idx == split_path.size
        # we are at the leaf node
        # see if we can find a result!
        if get_next
          return find_next_event(ge, val_matcher, sn.events)
        else
          return find_most_recent_event(ge, val_matcher, sn.events)
        end
      end

      # abort early if we know there's nothing good at this
      # node or in its children
      path_segment = split_path[idx]
      return res unless path_segment
      if path_segment.is_a?(Regexp)
        sn.children.each do |k, v|
          if path_segment.match(k)
            res2 = __get(ge, split_path, idx+1, val_matcher, v, res, get_next)
            if res2
              if res
                if get_next
                  res = res2 if res2 < res
                else
                  res = res2 if res2 > res
                end
              else
                res = res2
              end
            end
          end
        end
      elsif path_segment == '**'
        if split_path.size - 1 == idx
          # this is the last path_segment
          # search through all remaining ancestors for the
          # first logically timed event

          if get_next
            return next_ancestor_event(ge, val_matcher, sn, res)
          else
            return most_recent_ancestor_event(ge, val_matcher, sn, res)
          end
        else
          # if there is a next path segment then do a search
          # through all ancesters but only as far down as
          # ones with grand children matching the next segment
          # then continue as normal
          matching_ancestors(split_path[idx + 1], sn).each do |an|
            res2 = __get(ge, split_path, idx+2, val_matcher, an, res, get_next)
            if res2
              if res
                if get_next
                  res = res2 if res2 < res
                else
                  res = res2 if res2 > res
                end
              else
                res = res2
              end
            end
          end
        end
      else
        v = sn.children[path_segment]
        if v
          res2 = __get(ge, split_path, idx+1, val_matcher, v, res, get_next)
          if res2
            if res
              if get_next
                res = res2 if res2 < res
              else
                res = res2 if res2 > res
              end

            else
              res = res2
            end
          end
        end
      end
      return res
    end


    def __insert_event!(e, idx=0, sn=@state)
      if idx == e.path_size
        # we are at the leaf node

        # TODO: remove old events from start of events list
        # otherwise it will grow forever!

        sn.events.unshift(e)
        bubble_up_sort!(sn.events)
        return sn
      end

      # we are not at a leaf node, drill down....

      # get path segment

      path_segment = e.path_segment(idx)
      raise "Error inserting event - idx grew too large (#{idx} is bigger than #{e.path_size})" unless path_segment

      # get (or create) child node

      child_node = sn.children[path_segment] ||= EventHistoryNode.new

      # insert event into the child node
      __insert_event!(e, idx + 1, child_node)
      return sn
    end

    def bubble_up_sort!(events)
      # we assume that the events list is already ordered
      # however the item at idx may not be in the correct
      # place - therefore bubble it up by swapping with
      # the preceding elements in turn until the correct
      # place is found.

      idx = 0

      while (idx < events.size - 1) && (events[idx] < events[idx + 1])
        events[idx], events[idx + 1] = events[idx + 1], events[idx]
        idx += 1
      end
    end

    def wait_for_threads

    end

    def matching_ancestors(partial, n, res=[])
      matcher = partial.is_a? Regexp
      n.children.each do |k, v|
        if matcher
          res << v if partial.match(k)
        else
          res << v if partial == k
        end

        matching_ancestors(partial, v, res)
      end
      return res
    end


    def most_recent_ancestor_event(ge, val_matcher, n, res)
      n.children.values.each do |c|
        candidate = find_most_recent_event(ge, val_matcher, c.events)
        if candidate
          if res
            res = candidate if candidate > res
          else
            res = candidate
          end
        end

        ancestor_candidate = most_recent_ancestor_event(ge, val_matcher, c, res)
        if ancestor_candidate
          if res
            res = ancestor_candidate if ancestor_candidate > res
          else
            res = ancestor_candidate
          end
        end
      end
      return res
    end

    def next_ancestor_event(ge, val_matcher, n, res)
      n.children.values.each do |c|
        candidate = find_next_event(ge, val_matcher, c.events)
        if candidate
          if res
            res = candidate if candidate < res
          else
            res = candidate
          end
        end

        ancestor_candidate = next_ancestor_event(ge, val_matcher, c, res)
        if ancestor_candidate
          if res
            res = ancestor_candidate if ancestor_candidate < res
          else
            res = ancestor_candidate
          end
        end
      end
      return res
    end

    def find_most_recent_event(ge, val_matcher, events)
      if val_matcher
        events.find { |e|  e <= ge  && safe_matcher_call(val_matcher, e.val) }
      else
        events.find { |e|  e <= ge }
      end
    end

    def find_next_event(ge, val_matcher, events)
      return nil if events.empty?
      # Find the first match where time is greater than time t, d
      # events are ordered largest t ... smallest t
      # so actually find the first match where event's time is same or lt t, d
      #
      # Additionally if val_matcher is not nil, it is assumed to be a lambda
      # representing an arg matching fn. This will then be used asqo a constraint over the
      # val when finding a given event.

      # Find the first event that's less than the time t, d.
      idx = events.find_index { |e| e <= ge }
      if idx && idx > 0
        return events[idx -1] unless val_matcher
        while idx > 0
          idx -= 1
          return events[idx] if safe_matcher_call(val_matcher, events[idx].val)
        end
      end

      last = events.last
      if val_matcher
        return last if last && (last > ge) && safe_matcher_call(val_matcher, last.val)
      else
        return last if last && (last > ge)
      end
      return nil
    end

    def matcher?(p)
      p.include?('*')
    end
  end
end
