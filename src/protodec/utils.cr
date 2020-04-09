require "base64"
require "json"
require "uri"

module Protodec
  struct VarLong
    def self.from_io(io : IO, format = IO::ByteFormat::NetworkEndian) : Int64
      result = 0_i64
      num_read = 0

      loop do
        byte = io.read_byte
        raise "Invalid VarLong" if !byte
        value = byte & 0x7f

        result |= value.to_i64 << (7 * num_read)
        num_read += 1

        break if byte & 0x80 == 0
        raise "Invalid VarLong" if num_read > 10
      end

      result
    end

    def self.to_io(io : IO, value : Int64)
      io.write_byte 0x00 if value == 0x00
      value = value.to_u64!

      while value != 0
        byte = (value & 0x7f).to_u8!
        value >>= 7

        if value != 0
          byte |= 0x80
        end

        io.write_byte byte
      end
    end
  end

  struct Any
    enum Tag
      VarInt          = 0
      Bit64           = 1
      LengthDelimited = 2
      Bit32           = 5
    end

    TAG_MAP = {
      "varint"   => 0,
      "float32"  => 5,
      "int32"    => 5,
      "float64"  => 1,
      "int64"    => 1,
      "string"   => 2,
      "embedded" => 2,
      "base64"   => 2,
      "bytes"    => 2,
    }

    alias Type = Int32 |
                 Int64 |
                 Float64 |
                 String |
                 Array(UInt8) |
                 Hash(String, Any)

    getter raw : Type

    def initialize(@raw : Type)
    end

    def self.parse(io : IO)
      from_io(io, ignore_exceptions: true)
    end

    def self.from_io(io : IO, format = IO::ByteFormat::NetworkEndian, ignore_exceptions = false)
      item = new({} of String => Any)
      index = 0

      begin
        until io.size == io.pos
          begin
            header = io.read_bytes(VarLong)
          rescue ex
            next
          end

          field = (header >> 3).to_i
          type = Tag.new((header & 0b111).to_i)

          case type
          when Tag::VarInt
            value = io.read_bytes(VarLong)
            key = "#{field}:#{index}:varint"
          when Tag::Bit32
            value = io.read_bytes(Int32)
            bytes = IO::Memory.new
            value.to_io(bytes, IO::ByteFormat::LittleEndian)
            bytes.rewind

            begin
              value = bytes.read_bytes(Float32, format: IO::ByteFormat::LittleEndian).to_f64
              key = "#{field}:#{index}:float32"
            rescue ex
              value = value.to_i64
              key = "#{field}:#{index}:int32"
            end
          when Tag::Bit64
            value = io.read_bytes(Int64)
            bytes = IO::Memory.new
            value.to_io(bytes, IO::ByteFormat::LittleEndian)
            bytes.rewind

            begin
              value = bytes.read_bytes(Float64, format: IO::ByteFormat::LittleEndian)
              key = "#{field}:#{index}:float64"
            rescue ex
              key = "#{field}:#{index}:int64"
            end
          when Tag::LengthDelimited
            size = io.read_bytes(VarLong)
            raise "Invalid size" if size > 2**22

            bytes = Bytes.new(size)
            io.read_fully(bytes)

            value = String.new(bytes)
            if value.empty?
              value = ""
              key = "#{field}:#{index}:string"
            elsif value.valid_encoding? && !value.codepoints.any? { |codepoint|
                    (0x00..0x1f).includes?(codepoint) &&
                    !{0x09, 0x0a, 0x0d}.includes?(codepoint)
                  }
              begin
                value = from_io(IO::Memory.new(Base64.decode(URI.decode_www_form(URI.decode_www_form(value))))).raw
                key = "#{field}:#{index}:base64"
              rescue ex
                key = "#{field}:#{index}:string"
              end
            else
              begin
                value = from_io(IO::Memory.new(bytes)).raw
                key = "#{field}:#{index}:embedded"
              rescue ex
                value = bytes.to_a
                key = "#{field}:#{index}:bytes"
              end
            end
          else
            raise "Invalid type #{type}"
          end

          item[key] = value.as(Type)
          index += 1
        end
      rescue ex
        raise ex if !ignore_exceptions
      end

      item
    end

    def self.from_json(json : JSON::Any, format = IO::ByteFormat::NetworkEndian) : Bytes
      io = IO::Memory.new
      from_json(json, io, format)
      return io.to_slice
    end

    def self.from_json(json : JSON::Any, io : IO, format = IO::ByteFormat::NetworkEndian)
      case object = json.raw
      when Hash
        object.each do |key, value|
          parts = key.split(":")
          field = parts[0].to_i64
          type = parts[-1]

          header = (field << 3) | TAG_MAP[type]
          VarLong.to_io(io, header)

          case type
          when "varint"
            VarLong.to_io(io, value.raw.as(Number).to_i64!)
          when "int32"
            value.raw.as(Number).to_i32!.to_io(io, IO::ByteFormat::LittleEndian)
          when "float32"
            value.raw.as(Number).to_f32!.to_io(io, IO::ByteFormat::LittleEndian)
          when "int64"
            value.raw.as(Number).to_i64!.to_io(io, IO::ByteFormat::LittleEndian)
          when "float64"
            value.raw.as(Number).to_f64!.to_io(io, IO::ByteFormat::LittleEndian)
          when "string"
            VarLong.to_io(io, value.as_s.bytesize.to_i64)
            io.print value.as_s
          when "base64"
            buffer = IO::Memory.new
            from_json(value, buffer)
            buffer.rewind

            buffer = Base64.urlsafe_encode(buffer)
            VarLong.to_io(io, buffer.bytesize.to_i64)
            buffer.to_s(io)
          when "embedded"
            buffer = IO::Memory.new
            from_json(value, buffer)
            buffer.rewind

            VarLong.to_io(io, buffer.bytesize.to_i64)
            IO.copy(buffer, io)
          when "bytes"
            VarLong.to_io(io, value.size.to_i64)
            value.as_a.each { |byte| io.write_byte byte.as_i.to_u8 }
          else # "string"
            VarLong.to_io(io, value.to_s.bytesize.to_i64)
            io.print value.to_s
          end
        end
      else
        raise "Invalid value #{json}"
      end
    end

    # Assumes the underlying value is an `Array` or `Hash` and returns its size.
    # Raises if the underlying value is not an `Array` or `Hash`.
    def size : Int
      case object = @raw
      when Array
        object.size
      when Hash
        object.size
      else
        raise "Expected Array or Hash for #size, not #{object.class}"
      end
    end

    # Assumes the underlying value is an `Array` and returns the element
    # at the given index.
    # Raises if the underlying value is not an `Array`.
    # def [](index : Int) : Any
    #   case object = @raw
    #   when Array
    #     object[index]
    #   else
    #     raise "Expected Array for #[](index : Int), not #{object.class}"
    #   end
    # end

    def []=(key : String, value : Type)
      case object = @raw
      when Hash
        object[key] = Protodec::Any.new(value)
      else
        raise "Expected Hash for #[]=(key : String, value : Type), not #{object.class}"
      end
    end

    # Assumes the underlying value is an `Array` and returns the element
    # at the given index, or `nil` if out of bounds.
    # Raises if the underlying value is not an `Array`.
    def []?(index : Int) : Protodec::Any?
      case object = @raw
      when Array
        object[index]?
      else
        raise "Expected Array for #[]?(index : Int), not #{object.class}"
      end
    end

    # Assumes the underlying value is a `Hash` and returns the element
    # with the given key.
    # Raises if the underlying value is not a `Hash`.
    def [](key : String) : Protodec::Any
      case object = @raw
      when Hash
        object[key].as(Protodec::Any)
      else
        raise "Expected Hash for #[](key : String), not #{object.class}"
      end
    end

    # Assumes the underlying value is a `Hash` and returns the element
    # with the given key, or `nil` if the key is not present.
    # Raises if the underlying value is not a `Hash`.
    def []?(key : String) : Protodec::Any?
      case object = @raw
      when Hash
        object[key]?
      else
        raise "Expected Hash for #[]?(key : String), not #{object.class}"
      end
    end

    # Traverses the depth of a structure and returns the value.
    # Returns `nil` if not found.
    def dig?(key : String | Int, *subkeys)
      if (value = self[key]?) && value.responds_to?(:dig?)
        value.dig?(*subkeys)
      end
    end

    # :nodoc:
    def dig?(key : String | Int)
      self[key]?
    end

    # Traverses the depth of a structure and returns the value, otherwise raises.
    def dig(key : String | Int, *subkeys)
      if (value = self[key]) && value.responds_to?(:dig)
        return value.dig(*subkeys)
      end
      raise "Protodec::Any value not diggable for key: #{key.inspect}"
    end

    # :nodoc:
    def dig(key : String | Int)
      self[key]
    end

    # Checks that the underlying value is `Nil`, and returns `nil`.
    # Raises otherwise.
    def as_nil : Nil
      @raw.as(Nil)
    end

    # Checks that the underlying value is `Bool`, and returns its value.
    # Raises otherwise.
    def as_bool : Bool
      @raw.as(Bool)
    end

    # Checks that the underlying value is `Bool`, and returns its value.
    # Returns `nil` otherwise.
    def as_bool? : Bool?
      as_bool if @raw.is_a?(Bool)
    end

    # Checks that the underlying value is `Int`, and returns its value as an `Int32`.
    # Raises otherwise.
    def as_i : Int32
      @raw.as(Int).to_i
    end

    # Checks that the underlying value is `Int`, and returns its value as an `Int32`.
    # Returns `nil` otherwise.
    def as_i? : Int32?
      as_i if @raw.is_a?(Int)
    end

    # Checks that the underlying value is `Int`, and returns its value as an `Int64`.
    # Raises otherwise.
    def as_i64 : Int64
      @raw.as(Int).to_i64
    end

    # Checks that the underlying value is `Int`, and returns its value as an `Int64`.
    # Returns `nil` otherwise.
    def as_i64? : Int64?
      as_i64 if @raw.is_a?(Int64)
    end

    # Checks that the underlying value is `Float`, and returns its value as an `Float64`.
    # Raises otherwise.
    def as_f : Float64
      @raw.as(Float64)
    end

    # Checks that the underlying value is `Float`, and returns its value as an `Float64`.
    # Returns `nil` otherwise.
    def as_f? : Float64?
      @raw.as?(Float64)
    end

    # Checks that the underlying value is `Float`, and returns its value as an `Float32`.
    # Raises otherwise.
    def as_f32 : Float32
      @raw.as(Float).to_f32
    end

    # Checks that the underlying value is `Float`, and returns its value as an `Float32`.
    # Returns `nil` otherwise.
    def as_f32? : Float32?
      as_f32 if @raw.is_a?(Float)
    end

    # Checks that the underlying value is `String`, and returns its value.
    # Raises otherwise.
    def as_s : String
      @raw.as(String)
    end

    # Checks that the underlying value is `String`, and returns its value.
    # Returns `nil` otherwise.
    def as_s? : String?
      as_s if @raw.is_a?(String)
    end

    # Checks that the underlying value is `Array`, and returns its value.
    # Raises otherwise.
    def as_a : Array(Any)
      @raw.as(Array)
    end

    # Checks that the underlying value is `Array`, and returns its value.
    # Returns `nil` otherwise.
    def as_a? : Array(Any)?
      as_a if @raw.is_a?(Array)
    end

    # Checks that the underlying value is `Hash`, and returns its value.
    # Raises otherwise.
    def as_h : Hash(String, Any)
      @raw.as(Hash)
    end

    # Checks that the underlying value is `Hash`, and returns its value.
    # Returns `nil` otherwise.
    def as_h? : Hash(String, Any)?
      as_h if @raw.is_a?(Hash)
    end

    # :nodoc:
    def inspect(io : IO) : Nil
      @raw.inspect(io)
    end

    # :nodoc:
    def to_s(io : IO) : Nil
      @raw.to_s(io)
    end

    # :nodoc:
    def pretty_print(pp)
      @raw.pretty_print(pp)
    end

    # Returns `true` if both `self` and *other*'s raw object are equal.
    def ==(other : Protodec::Any)
      raw == other.raw
    end

    # Returns `true` if the raw object is equal to *other*.
    def ==(other)
      raw == other
    end

    # See `Object#hash(hasher)`
    def_hash raw

    # :nodoc:
    def to_json(json : JSON::Builder)
      raw.to_json(json)
    end

    def to_yaml(yaml : YAML::Nodes::Builder)
      raw.to_yaml(yaml)
    end

    # Returns a new Protodec::Any instance with the `raw` value `dup`ed.
    def dup
      Any.new(raw.dup)
    end

    # Returns a new Protodec::Any instance with the `raw` value `clone`ed.
    def clone
      Any.new(raw.clone)
    end

    def self.cast_json(object)
      raise "Invalid type" if !object.is_a?(Hash)

      JSON::Any.new(object.transform_values do |value|
        case value
        when .is_a?(Hash)
          cast_json(value)
        when .is_a?(Protodec::Any)
          case raw = value.raw
          when Array(UInt8)
            JSON::Any.new(raw.map { |i| JSON::Any.new(i.to_i64) })
          when Int32
            JSON::Any.new(raw.to_i64)
          when Hash(String, Protodec::Any)
            cast_json(raw)
          else
            JSON::Any.new(raw)
          end
        else
          JSON::Any.new(value)
        end
      end)
    end
  end
end
