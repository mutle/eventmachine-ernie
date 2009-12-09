require 'eventmachine'
require 'bert'
require 'logger'

class Ernie
  class << self
    attr_accessor :mods, :current_mod, :log
    attr_accessor :auto_start, :server_options
  end

  self.mods = {}
  self.current_mod = nil
  self.log = Logger.new(STDOUT)
  log.level = Logger::INFO
  self.auto_start = true
  self.server_options = {}

  # Record a module.
  #   +name+ is the module Symbol
  #   +block+ is the Block containing function definitions
  #
  # Returns nothing
  def self.mod(name, block)
    m = Mod.new(name)
    self.current_mod = m
    self.mods[name] = m
    block.call
  end

  # Record a function.
  #   +name+ is the function Symbol
  #   +block+ is the Block to associate
  #
  # Returns nothing
  def self.fun(name, block)
    self.current_mod.fun(name, block)
  end

  # Expose all public methods in a Ruby module:
  #   +name+ is the ernie module Symbol
  #   +mixin+ is the ruby module whose public methods are exposed
  #
  # Returns nothing
  def self.expose(name, mixin)
    context = Object.new
    context.extend mixin
    mod(name, lambda {
      mixin.public_instance_methods.each do |meth|
        fun(meth.to_sym, context.method(meth))
      end
    })
    context
  end

  # Set the logfile to given path.
  #   +file+ is the String path to the logfile
  #
  # Returns nothing
  def self.logfile(file)
    self.log = Logger.new(file)
  end

  # Set the log level.
  #   +level+ is the Logger level (Logger::WARN, etc)
  #
  # Returns nothing
  def self.loglevel(level)
    log.level = level
  end

  # Dispatch the request to the proper mod:fun.
  #   +mod+ is the module Symbol
  #   +fun+ is the function Symbol
  #   +args+ is the Array of arguments
  #
  # Returns the Ruby object response
  def self.dispatch(mod, fun, args)
    self.mods[mod] || raise(ServerError.new("No such module '#{mod}'"))
    self.mods[mod].funs[fun] || raise(ServerError.new("No such function '#{mod}:#{fun}'"))
    self.mods[mod].funs[fun].call(*args)
  end


  # Start the processing loop.
  #
  # Loops forever
  def self.start
    EM.run {
      port = self.server_options[:port]
      EM.start_server "0.0.0.0", port, Ernie::Connection
      self.log.info "started server on port #{port}"
    }
  end

  class Connection < EventMachine::Connection
    def log; Ernie.log; end

    def receive_data(data)
      iruby = read_berp(data)
      unless iruby
        puts "Could not read BERP length header. Ernie server may have gone away. Exiting now."
        log.info("(#{Process.pid}) Could not read BERP length header. Ernie server may have gone away. Exiting now.")
        exit!
      end

      if iruby.size == 4 && iruby[0] == :call
        mod, fun, args = iruby[1..3]
        log.info("-> " + iruby.inspect)
        begin
          res = Ernie.dispatch(mod, fun, args)
          oruby = t[:reply, res]
          log.debug("<- " + oruby.inspect)
          write_berp(oruby)
        rescue ServerError => e
          oruby = t[:error, t[:server, 0, e.class.to_s, e.message, e.backtrace]]
          log.error("<- " + oruby.inspect)
          log.error(e.backtrace.join("\n"))
          write_berp(oruby)
        rescue Object => e
          oruby = t[:error, t[:user, 0, e.class.to_s, e.message, e.backtrace]]
          log.error("<- " + oruby.inspect)
          log.error(e.backtrace.join("\n"))
          write_berp(oruby)
        end
      elsif iruby.size == 4 && iruby[0] == :cast
        mod, fun, args = iruby[1..3]
        log.info("-> " + [:cast, mod, fun, args].inspect)
        begin
          Ernie.dispatch(mod, fun, args)
        rescue Object => e
          # ignore
        end
        write_berp(t[:noreply])
      else
        log.error("-> " + iruby.inspect)
        oruby = t[:error, t[:server, 0, "Invalid request: #{iruby.inspect}"]]
        log.error("<- " + oruby.inspect)
        write_berp(oruby)
      end
    end

    private
    # Read the length header from the wire.
    #   +input+ is the IO from which to read
    #
    # Returns the size Integer if one was read
    # Returns nil otherwise
    def read_4(input)
      raw = input.read(4)
      return nil unless raw
      raw.unpack('N').first
    end

    # Read a BERP from the wire and decode it to a Ruby object.
    #   +input+ is the IO from which to read
    #
    # Returns a Ruby object if one could be read
    # Returns nil otherwise
    def read_berp(input)
      input = StringIO.new(input)
      packet_size = read_4(input)
      return nil unless packet_size
      bert = input.read(packet_size)
      BERT.decode(bert)
    end

    # Write the given Ruby object to the wire as a BERP.
    #   +ruby+ is the Ruby object to encode
    #
    # Returns nothing
    def write_berp(ruby)
      data = BERT.encode(ruby)
      send_data [data.length].pack("N")
      send_data data
    end
  end

end

class Ernie::ServerError < StandardError; end

class Ernie::Mod
  attr_accessor :name, :funs

  def initialize(name)
    self.name = name
    self.funs = {}
  end

  def fun(name, block)
    raise TypeError, "block required" if block.nil?
    self.funs[name] = block
  end
end

# Root level calls

def mod(name, &block)
  Ernie.mod(name, block)
end

def fun(name, &block)
  Ernie.fun(name, block)
end

def logfile(name)
  Ernie.logfile(name)
end

def loglevel(level)
  Ernie.loglevel(level)
end
