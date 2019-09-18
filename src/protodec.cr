# protodec (which is a command-line decoder for arbitrary protobuf data)
# Copyright (C) 2019  Omar Roth

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

require "base64"
require "option_parser"
require "uri"

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
    value = value.to_u64

    while value != 0
      byte = (value & 0x7f).to_u8
      value >>= 7

      if value != 0
        byte |= 0x80
      end

      io.write_byte byte
    end
  end
end

struct ProtoBuf::Any
  enum Tag
    VarInt          = 0
    Bit64           = 1
    LengthDelimited = 2
    Bit32           = 5
  end

  alias Type = Int64 |
               Bytes |
               String |
               Hash(Int32, Type)

  getter raw : Type

  def initialize(@raw : Type)
  end

  def self.parse(io : IO)
    from_io(io, ignore_exceptions: true)
  end

  def self.from_io(io : IO, format = IO::ByteFormat::NetworkEndian, ignore_exceptions = false)
    item = new({} of Int32 => Type)

    begin
      until io.pos == io.size
        header = io.read_bytes(VarLong)
        field = (header >> 3).to_i
        type = Tag.new((header & 0b111).to_i)

        case type
        when Tag::VarInt
          value = io.read_bytes(VarLong)
        when Tag::Bit64
          value = Bytes.new(8)
          io.read_fully(value)
        when Tag::LengthDelimited
          bytes = Bytes.new(io.read_bytes(VarLong))
          io.read_fully(bytes)

          if bytes.empty?
            value = ""
          else
            begin
              value = from_io(IO::Memory.new(Base64.decode(URI.unescape(String.new(bytes))))).raw
            rescue ex
              if bytes.all? { |byte| {'\t'.ord, '\n'.ord, '\r'.ord}.includes?(byte) || byte >= 0x20 }
                value = String.new(bytes)
              else
                begin
                  value = from_io(IO::Memory.new(bytes)).raw
                rescue ex
                  value = bytes
                end
              end
            end
          end
        when Tag::Bit32
          value = Bytes.new(4)
          io.read_fully(value)
        else
          break if ignore_exceptions
          raise "Invalid type #{type}"
        end

        item[field] = value.as(Type)
      end
    end

    item
  end

  def []=(key : Int32, value : Type)
    case object = @raw
    when Hash
      object[key] = value
    else
      raise "Expected Hash for #[]=(key : Int32, value : Type), not #{object.class}"
    end
  end
end

enum InputType
  Base64
  Hex
end

input_type = InputType::Hex

OptionParser.parse! do |parser|
  parser.banner = "Usage: protodec [arguments]\n"
  parser.on("-d", "--decode", "STDIN is Base64-encoded") { input_type = InputType::Base64 }
  parser.on("-h", "--help", "Show this help") { puts parser }
end

input = STDIN.gets_to_end
case input_type
when InputType::Hex
  array = input.split("-").map &.to_i(16).to_u8
  input = Slice.new(array.size) { |i| array[i] }
when InputType::Base64
  input = Base64.decode(URI.unescape(input))
end

pp ProtoBuf::Any.parse(IO::Memory.new(input)).raw
