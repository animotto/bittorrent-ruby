# frozen_string_literal: true

require 'socket'

module BitTorrent
  ##
  # Peer communication
  class Peer
    HANDSHAKE_STRING = 'BitTorrent protocol'

    MSG_CHOKE_ID = 0
    MSG_UNCHOKE_ID = 1
    MSG_INTERESTED_ID = 2
    MSG_NOTINTERESTED_ID = 3
    MSG_HAVE_ID = 4
    MSG_BITFIELD_ID = 5
    MSG_REQUEST_ID = 6
    MSG_PIECE_ID = 7
    MSG_CANCEL_ID = 8
    MSG_PORT_ID = 9

    CALLBACKS = {
      MSG_CHOKE_ID => :on_msg_choke,
      MSG_UNCHOKE_ID => :on_msg_unchoke,
      MSG_INTERESTED_ID => :on_msg_interested,
      MSG_NOTINTERESTED_ID => :on_msg_notinterested,
      MSG_HAVE_ID => :on_msg_have,
      MSG_BITFIELD_ID => :on_msg_bitfield,
      MSG_REQUEST_ID => :on_msg_request,
      MSG_PIECE_ID => :on_msg_piece,
      MSG_CANCEL_ID => :on_msg_cancel,
      MSG_PORT_ID => :on_msg_port
    }.freeze

    CONNECT_TIMEOUT = 5
    IO_WAIT_TIMEOUT = 1
    KEEPALIVE_INTERVAL = 60

    attr_accessor :client_choked, :client_interested, :peer_choked, :peer_interested, :bitfield

    def initialize(ip, port)
      @ip = ip
      @port = port
      @opened = false
      @bitfield = Bitfield.new
      @callbacks = {}
      @client_choked = true
      @client_interested = false
      @peer_choked = true
      @peer_interested = false
    end

    ##
    # Opens peer connection
    def open(client_id, info_hash, timeout: CONNECT_TIMEOUT)
      raise PeerError, 'The connection is already opened' if opened?

      @client_id = client_id
      @info_hash = info_hash
      @socket = Socket.tcp(@ip, @port, connect_timeout: timeout)
      @opened = true
    end

    ##
    # Closes peer connection
    def close
      @socket.close
      @opened = false
    end

    ##
    # Returns true if connection is opened
    def opened?
      @opened
    end

    ##
    # Returns true if client choked
    def client_choked?
      @client_choked
    end

    ##
    # Returns true if client interested
    def client_interested?
      @client_interested
    end

    ##
    # Returns true if peer choked
    def peer_choked?
      @peer_choked
    end

    ##
    # Returns true if peer interested
    def peer_interested?
      @peer_interested
    end

    ##
    # Callback methods
    def method_missing(method, **_args, &block)
      return unless method.start_with?('on_')

      @callbacks[method] = block
    end

    ##
    # List of callback methods
    def respond_to_missing?(method)
      @callbacks.key?(method)
    end

    ##
    # Runs the connection dispatcher
    def run
      @handshake = msg_handshake
      callback(:on_msg_handshake, @handshake)
      loop do
        begin
          message = receive
          if message[:id].nil?
            message_class = MessageKeepAlive
          else
            message_class = Message.successors.detect { |m| m::ID == message[:id] }
            message_class = MessageUnknown if message_class.nil?
          end

          message = message_class.new(self, message[:payload])
          callback(:on_message, message)
          if message.instance_of?(MessageKeepAlive)
            callback(:on_msg_keepalive, message)
            next
          end

          callback(CALLBACKS[message.id], message)
        rescue IOError
          return
        end
      end
    end

    ##
    # Does peer handshake
    def msg_handshake
      write([HANDSHAKE_STRING.length].pack('C'))
      write(HANDSHAKE_STRING)
      write([0].pack('Q>'))
      write(@info_hash)
      write(@client_id)

      handshake = {}
      length = read(1).unpack1('C')
      handshake[:string] = read(length)
      handshake[:reserved] = read(8).unpack1('Q>')
      handshake[:info_hash] = read(20)
      handshake[:peer_id] = read(20)

      raise PeerError, 'Peer info hash mismatch' if @info_hash != handshake[:info_hash]

      handshake
    end

    ##
    # Sends keep-alive
    def msg_keepalive
      send
    end

    ##
    # Chokes a peer
    def msg_choke
      send(id: MSG_CHOKE_ID)
      @peer_choked = true
    end

    ##
    # Unchokes a peer
    def msg_unchoke
      send(id: MSG_UNCHOKE_ID)
      @peer_choked = false
    end

    ##
    # Interests a client
    def msg_interested
      send(id: MSG_INTERESTED_ID)
      @client_interested = true
    end

    ##
    # Not interests a client
    def msg_notinterested
      send(id: MSG_NOTINTERESTED_ID)
      @client_interested = false
    end

    ##
    # Sends the index of the piece that the client has
    def msg_have(index)
      payload = [index].pack('L>')
      send(id: MSG_HAVE_ID, payload: payload)
    end

    ##
    # Sends the bitfield
    def msg_bitfield(bitfield)
      send(id: MSG_BITFIELD_ID, payload: bitfield)
    end

    ##
    # Requests the block from the peer
    def msg_request(index, start, length)
      payload = [index, start, length].pack('L>3')
      send(id: MSG_REQUEST_ID, payload: payload)
    end

    ##
    # Sends the block of the piece
    def msg_piece(index, start, block)
      payload = [index, start, block].pack('L>2a*')
      send(id: MSG_PIECE_ID, payload: payload)
    end

    ##
    # Cancels piece request
    def msg_cancel(index, start, length)
      payload = [index, start, length].pack('L>3')
      send(id: MSG_CANCEL_ID, payload: payload)
    end

    ##
    # Sends the port number
    def msg_port(port)
      payload = [port].pack('S>')
      send(id: MSG_PORT_ID, payload: payload)
    end

    private

    ##
    # Calls calback
    def callback(name, message)
      return unless @callbacks.key?(name)

      @callbacks[name].call(message)
    end

    ##
    # Executes when there is no data after non blocking read the socket
    def nodata
      return if @last_send.nil? || Time.now - @last_send < KEEPALIVE_INTERVAL

      msg_keepalive
    end

    ##
    # Reads the socket
    def read(length)
      raise PeerError, 'The connection not opened' unless opened?

      data = String.new
      while data.bytesize < length
        begin
          nodata unless @socket.wait_readable(IO_WAIT_TIMEOUT)
          data << @socket.read_nonblock(length - data.bytesize)
        rescue EOFError
          raise PeerError, 'Connection closed'
        rescue IO::WaitReadable
          retry
        end
      end
      data
    end

    ##
    # Writes to the socket
    def write(data)
      raise PeerError, 'The connection not opened' unless opened?

      @socket.write(data)
      @last_send = Time.now
    end

    ##
    # Receives a message
    def receive
      message = {}
      message[:length] = read(4).unpack1('L>')
      unless message[:length].zero?
        message[:id] = read(1).unpack1('C')
        length = message[:length] - 1
        message[:payload] = read(length) unless length.zero?
      end
      message
    end

    ##
    # Sends a message
    def send(**message)
      length = message.key?(:id) ? 1 : 0
      length += message[:payload].bytesize if message.key?(:payload)
      write([length].pack('L>'))
      return if length.zero?

      write([message[:id]].pack('C'))
      write(message[:payload]) if message.key?(:payload)
    end
  end

  ##
  # Message
  class Message
    @@successors = []

    class << self
      def inherited(subclass)
        super
        @@successors << subclass
      end

      def successors
        @@successors
      end
    end

    attr_reader :payload

    def initialize(peer, payload)
      @peer = peer
      @payload = payload
      unpack
    end

    def id
      self.class::ID
    end

    private

    def unpack; end
  end

  ##
  # Message Choke
  class MessageChoke < Message
    ID = Peer::MSG_CHOKE_ID

    private

    def unpack
      @peer.client_choked = true
    end
  end

  ##
  # Message Unchoke
  class MessageUnchoke < Message
    ID = Peer::MSG_UNCHOKE_ID

    private

    def unpack
      @peer.client_choked = false
    end
  end

  ##
  # Message Interested
  class MessageInterested < Message
    ID = Peer::MSG_INTERESTED_ID

    private

    def unpack
      @peer.peer_interested = true
    end
  end

  ##
  # Message NotInterested
  class MessageNotInterested < Message
    ID = Peer::MSG_NOTINTERESTED_ID

    private

    def unpack
      @peer.peer_interested = false
    end
  end

  ##
  # Message Have
  class MessageHave < Message
    ID = Peer::MSG_HAVE_ID

    attr_reader :index

    private

    def unpack
      @index = @payload.unpack1('L>')
      @peer.bitfield.add_piece(@index)
    end
  end

  ##
  # Message Bitfield
  class MessageBitfield < Message
    ID = Peer::MSG_BITFIELD_ID

    private

    def unpack
      @peer.bitfield = Bitfield.new(bitfield: @payload)
    end
  end

  ##
  # Message Request
  class MessageRequest < Message
    ID = Peer::MSG_REQUEST_ID

    attr_reader :index, :start, :length

    private

    def unpack
      @index, @start, @length = @payload.unpack('L>3')
    end
  end

  ##
  # Message Piece
  class MessagePiece < Message
    ID = Peer::MSG_PIECE_ID

    attr_reader :index, :start, :block

    private

    def unpack
      @index, @start, @block = @payload.unpack('L>2a*')
    end
  end

  ##
  # Message Cancel
  class MessageCancel < Message
    ID = Peer::MSG_CANCEL_ID

    attr_reader :index, :start, :length

    private

    def unpack
      @index, @start, @length = @payload.unpack('L>3')
    end
  end

  ##
  # Message Port
  class MessagePort < Message
    ID = Peer::MSG_PORT_ID

    attr_reader :port

    private

    def unpack
      @port = @payload.unpack('S>')
    end
  end

  ##
  # Message KeepAlive
  class MessageKeepAlive < Message
    ID = nil
  end

  ##
  # Message Unknown
  class MessageUnknown < Message
    ID = nil
  end

  ##
  # Bitfield
  class Bitfield
    def initialize(bitfield: nil)
      @bitfield = []
      @bitfield = bitfield.unpack('C*') unless bitfield.nil?
    end

    ##
    # Returns true if the piece exists
    def piece?(index)
      i = index / 8
      b = (index % 8 - 7).abs
      return false if @bitfield[i].nil?

      (@bitfield[i] >> b) & 1 == 1
    end

    ##
    # Adds a piece to the bitfield
    def add_piece(index)
      n = index / 8 + 1
      (n - @bitfield.length).times { @bitfield << 0 } if n > @bitfield.length

      i = index / 8
      b = (index % 8 - 7).abs
      @bitfield[i] |= 1 << b
    end

    ##
    # Removes a piece from the bitfield
    def remove_piece(index)
      i = index / 8
      b = (index % 8 - 7).abs
      return if @bitfield[i].nil?

      @bitfield[i] &= ~(1 << b)
    end

    ##
    # Returns an array of pieces indices
    def pieces
      list = []
      (@bitfield.length * 8).times { |i| list << i if piece?(i) }
      list
    end

    ##
    # Returns bitfield as a string
    def to_s
      @bitfield.pack('C*')
    end
  end

  class PeerError < StandardError; end
end
