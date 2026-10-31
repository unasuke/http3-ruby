# frozen_string_literal: true

module HTTP3
  # Threads that run the jobs posted to them, one at a time each:
  #
  #   pool = HTTP3::WorkerPool.new(3)
  #   pool.start
  #   pool.post { ... }
  #   pool.stop(1) # => the threads still running after a second
  #
  # The pool does not count the free threads: Server posts only as many
  # jobs as there are, so none waits for long.
  class WorkerPool
    # The priority of the threads. MRI shortens a thread's time slice of
    # 100 ms by its negative priority, halving it for each step, so at -3,
    # the least, a worker busy on the CPU keeps the thread that drives the
    # connections waiting for the GVL 12.5 ms at a time. Which thread gets
    # the GVL next does not change.
    WORKER_PRIORITY = -3

    def initialize(size)
      @size = size
      @jobs = Thread::Queue.new
      @threads = []
    end

    # Make the threads, named "http3-worker-1" and on.
    def start
      @threads = Array.new(@size) do |i|
        Thread.new { work }.tap do |thread|
          thread.name = "http3-worker-#{i + 1}"
          thread.priority = WORKER_PRIORITY
          thread.report_on_exception = false
        end
      end
      self
    end

    # Queue job for the next free thread, without waiting.
    def post(&job)
      @jobs << job
      self
    end

    # Drop the jobs not started, let each thread end once its job is done,
    # and wait up to timeout seconds for them all. Returns the number of
    # threads still running.
    def stop(timeout)
      @jobs.clear
      @jobs.close
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @threads.count do |thread|
        thread.join([deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max).nil?
      end
    end

    private

    def work
      while (job = @jobs.pop)
        begin
          job.call
        rescue Exception # rubocop:disable Lint/RescueException
          # A job reports its own failures. Even exit in one leaves the
          # thread for the next.
          nil
        end
      end
    end
  end
end
