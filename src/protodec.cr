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
require "json"
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
end

struct ProtoBuf::Any
  enum Tag
    VarInt          = 0
    Bit64           = 1
    LengthDelimited = 2
    Bit32           = 5
  end

  alias Type = Int64 |
               Float64 |
               Array(UInt8) |
               String |
               Hash(String, Type)

  getter raw : Type

  def initialize(@raw : Type)
  end

  def self.parse(io : IO)
    from_io(io, ignore_exceptions: true)
  end

  def self.from_io(io : IO, format = IO::ByteFormat::NetworkEndian, ignore_exceptions = false)
    item = new({} of String => Type)
    index = 0

    begin
      until io.pos == io.size
        header = io.read_bytes(VarLong)
        field = (header >> 3).to_i
        type = Tag.new((header & 0b111).to_i)

        case type
        when Tag::VarInt
          value = io.read_bytes(VarLong)
        when Tag::Bit32
          value = io.read_bytes(Int32)
          bytes = IO::Memory.new
          value.to_io(bytes, IO::ByteFormat::LittleEndian)
          bytes.rewind

          begin
            value = bytes.read_bytes(Float32, format: IO::ByteFormat::LittleEndian).to_f64
          rescue ex
            value = value.to_i64
          end
        when Tag::Bit64
          value = io.read_bytes(Int64)
          bytes = IO::Memory.new
          value.to_io(bytes, IO::ByteFormat::LittleEndian)
          bytes.rewind

          begin
            value = bytes.read_bytes(Float64, format: IO::ByteFormat::LittleEndian)
          rescue ex
          end
        when Tag::LengthDelimited
          size = io.read_bytes(VarLong)
          raise "Invalid size" if size > 2**20

          bytes = Bytes.new(size)
          io.read_fully(bytes)

          value = String.new(bytes)
          if value.empty?
            value = ""
          elsif value.valid_encoding? && !value.codepoints.any? { |codepoint|
                  (0x00..0x1f).includes?(codepoint) &&
                  !{0x09, 0x0a, 0x0d}.includes?(codepoint)
                }
            begin
              value = from_io(IO::Memory.new(Base64.decode(URI.unescape(URI.unescape(value))))).raw
            rescue ex
            end
          else
            begin
              value = from_io(IO::Memory.new(bytes)).raw
            rescue ex
              value = bytes.to_a
            end
          end
        else
          raise "Invalid type #{type}"
        end

        item["#{field}:#{index}"] = value.as(Type)
        index += 1
      end
    rescue ex
      raise ex if !ignore_exceptions
    end

    item
  end

  def []=(key : String, value : Type)
    case object = @raw
    when Hash
      object[key] = value
    else
      raise "Expected Hash for #[]=(key : String, value : Type), not #{object.class}"
    end
  end

  def to_json
    raw.to_json
  end

  def to_json(json)
    raw.to_json(json)
  end
end

enum InputType
  Base64
  Hex
  Raw
end

enum OutputType
  Json
  JsonPretty
end

input_type = InputType::Raw
output_type = OutputType::Json
flags = [] of String

OptionParser.parse! do |parser|
  parser.banner = <<-'END_USAGE'
  Usage: protodec [arguments]
  Command-line decoder for arbitrary protobuf data. Reads from standard input.
  END_USAGE

  parser.on("-d", "--decode", "STDIN is Base64-encoded") { flags << "d" }
  parser.on("-x", "--hex", "STDIN is space-separated hexstring") { flags << "x" }
  parser.on("-r", "--raw", "STDIN is raw binary data (default)") { flags << "r" }
  parser.on("-p", "--pretty", "Pretty print output") { flags << "p" }
  parser.on("-h", "--help", "Show this help") { STDOUT.puts parser; exit(0) }

  parser.invalid_option do |option|
    flags += option.split("")[1..-1]
  end
end

flags.each do |flag|
  case flag
  when "d"
    input_type = InputType::Base64
  when "x"
    input_type = InputType::Hex
  when "r"
    input_type = InputType::Raw
  when "p"
    output_type = OutputType::JsonPretty
  else
    STDERR.puts "ERROR: #{flag} is not a valid option."
    exit(1)
  end
end

input = STDIN.gets_to_end
case input_type
when InputType::Base64
  input = Base64.decode(URI.unescape(URI.unescape(input.strip)))
when InputType::Hex
  array = input.strip.split(/[- ,]+/).map &.to_i(16).to_u8
  input = Slice.new(array.size) { |i| array[i] }
when InputType::Raw
end

output = ProtoBuf::Any.parse(IO::Memory.new(input))
case output_type
when OutputType::Json
  STDOUT.puts output.to_json
when OutputType::JsonPretty
  STDOUT.puts output.to_pretty_json
end
