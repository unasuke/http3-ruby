# frozen_string_literal: true

require "test_helper"

class TestWorkerPool < Minitest::Test
  def setup
    @pools = []
    @pipes = []
  end

  def teardown
    @pipes.flatten.each { |io| io.close unless io.closed? }
    @pools.each { |pool| pool.stop(1) }
  end

  # Busy for a while each, two jobs go to two threads.
  def test_threads_are_named_and_have_the_least_priority
    pool = new_pool(2)
    seen = Thread::Queue.new
    2.times do
      pool.post do
        seen << [Thread.current.name, Thread.current.priority]
        sleep 0.2
      end
    end
    workers = Array.new(2) { seen.pop(timeout: 5) }.sort
    assert_equal [["http3-worker-1", -3], ["http3-worker-2", -3]], workers
    assert_equal(-3, HTTP3::WorkerPool::WORKER_PRIORITY)
  end

  # A job that raises, or even exits, leaves its thread for the next job.
  def test_a_job_that_raises_or_exits_keeps_its_thread
    pool = new_pool(1)
    done = Thread::Queue.new
    pool.post { raise "the job failed" }
    pool.post { exit }
    pool.post { done << Thread.current.name }
    assert_equal "http3-worker-1", done.pop(timeout: 5)
  end

  def test_stop_ends_the_threads
    pool = new_pool(2)
    seen = Thread::Queue.new
    2.times do
      pool.post do
        seen << Thread.current
        sleep 0.2
      end
    end
    workers = Array.new(2) { seen.pop(timeout: 5) }
    assert_equal 0, pool.stop(5)
    workers.each { |thread| refute_predicate thread, :alive? }
  end

  # stop drops the jobs not started, waits no longer than it is told for
  # those under way, and tells how many threads are still running.
  def test_stop_counts_the_threads_still_running
    pool = new_pool(2)
    reader, writer = IO.pipe
    @pipes << [reader, writer]
    started = Thread::Queue.new
    ran = Thread::Queue.new
    2.times do
      pool.post do
        started << Thread.current
        reader.read(1)
      end
    end
    pool.post { ran << true }
    workers = Array.new(2) { started.pop(timeout: 5) }
    assert_equal 2, pool.stop(0.1)
    writer.write("xx")
    workers.each { |thread| assert thread.join(5), "the thread should end once its job is done" }
    assert_empty ran
  end

  private

  def new_pool(size)
    HTTP3::WorkerPool.new(size).start.tap { |pool| @pools << pool }
  end
end
