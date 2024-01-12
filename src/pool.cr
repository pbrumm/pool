require "mt_helpers"

# Generic pool.
#
# It will create N instances that can be checkin then checkout. Trying to
# checkout an instance from an empty pool will block until another coroutine
# checkin an instance back, up until a timeout is reached.
class Pool(T)
  # TODO: shutdown (close all connections)
  # FIXME: thread safety

  # Returns how many instances can be started at maximum capacity.
  getter capacity

  # Returns how much time to wait for an instance to be available before raising
  # a Timeout exception.
  getter timeout

  # Returns how many instances are available for checkout.
  getter pending

  # Returns how many instances have been started.
  getter size

  private getter pool

  @r : IO::FileDescriptor
  @w : IO::FileDescriptor

  def initialize(@capacity : Int32 = 5, @timeout : Float64 = 5.0, &block : -> T)
    @r, @w = IO.pipe(read_blocking: false, write_blocking: false)
    @r.read_timeout = @timeout
    @mutex = Mutex.new
    @buffer = Slice(UInt8).new(1)
    @size = 0
    @pending = @capacity
    @pool = SafeArray(T).new
    @block = block
  end

  def start_all
    @mutex.synchronize do
      until size >= @capacity
        start_one
      end
    end
  end

  def close_all
    @mutex.synchronize do
      while connection = @pool.shift?
        @size -= 1
        begin
          connection.close
        rescue Exception
        end
      end
      @size = @pool.size
    end
  end

  # Checkout an instance from the pool. Blocks until an instance is available if
  # all instances are busy. Eventually raises an `IO::Timeout` error.
  def checkout : T
    @mutex.synchronize do
      loop do
        if pool.empty? && size < @capacity
          start_one
        end

        @r.read(@buffer)

        if obj = pool.shift?
          @pending -= 1
          return obj
        end
      end
    end
  end

  # Checkin an instance back into the pool.
  def checkin(connection : T)
    @mutex.synchronize do
      unless pool.includes?(connection)
        pool << connection
        @pending += 1
        @w.write(@buffer)
      end
    end
  end

  private def start_one
    pool << @block.call
    @size += 1
    @w.write(@buffer)
  end
end
