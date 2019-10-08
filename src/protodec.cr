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

CURRENT_BRANCH  = {{ "#{`git branch | sed -n '/\* /s///p'`.strip}" }}
CURRENT_COMMIT  = {{ "#{`git rev-list HEAD --max-count=1 --abbrev-commit`.strip}" }}
CURRENT_VERSION = {{ "#{`git describe --tags --abbrev=0`.strip}" }}

SOFTWARE = {
  "name"    => "protodec",
  "version" => "#{CURRENT_VERSION}-#{CURRENT_COMMIT}",
  "branch"  => "#{CURRENT_BRANCH}",
}

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

          buffer = Base64.urlsafe_encode(buffer, padding: false)
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
        end
      end
    else
      raise "Invalid value #{json}"
    end
  end
end

enum IOType
  Base64
  Hex
  Raw
  Json
  JsonPretty
end

input_type = nil
output_type = nil
flags = [] of String

OptionParser.parse do |parser|
  parser.banner = <<-'END_USAGE'
  Usage: protodec [arguments]
  Command-line encoder and decoder for arbitrary protobuf data. Reads from standard input.
  END_USAGE

  parser.on("-e", "--encode", "Encode input") { flags << "e" }
  parser.on("-d", "--decode", "Decode input (default)") { flags << "d" }
  parser.on("-b", "--base64", "STDIN is Base64-encoded") { flags << "b" }
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
  when "b"
    input_type = IOType::Base64
  when "x"
    input_type = IOType::Hex
  when "r"
    input_type = IOType::Raw
  when "p"
    output_type = IOType::JsonPretty
  when "e", "d"
  when "v"
    if flags.includes? "p"
      STDOUT.puts SOFTWARE.to_pretty_json
    else
      STDOUT.puts SOFTWARE.to_json
    end
    exit(0)
  else
    STDERR.puts "ERROR: #{flag} is not a valid option."
    exit(1)
  end
end

if flags.includes? "e"
  tmp = output_type
  output_type = input_type
  input_type = tmp

  input_type ||= IOType::Json
  output_type ||= IOType::Base64
else
  input_type ||= IOType::Raw
  output_type ||= IOType::Json
end

case input_type
when IOType::Base64
  output = ProtoBuf::Any.parse(IO::Memory.new(Base64.decode(URI.decode_www_form(URI.decode_www_form(STDIN.gets_to_end.strip)))))
when IOType::Hex
  array = STDIN.gets_to_end.strip.split(/[- ,]+/).map &.to_i(16).to_u8
  output = ProtoBuf::Any.parse(IO::Memory.new(Slice.new(array.size) { |i| array[i] }))
when IOType::Raw
  output = ProtoBuf::Any.parse(IO::Memory.new(STDIN.gets_to_end))
when IOType::Json, IOType::JsonPretty
  output = IO::Memory.new
  ProtoBuf::Any.from_json(JSON.parse(STDIN), output)
else
  output = ""
end

case output_type
when IOType::Base64
  STDOUT.puts Base64.urlsafe_encode(output.as(IO))
when IOType::Hex
  STDOUT.puts (output.as(IO).to_slice.map &.to_s(16).rjust(2, '0').upcase).join("-")
when IOType::Raw
  STDOUT.write output.as(IO).to_slice
when IOType::Json
  STDOUT.puts output.as(ProtoBuf::Any).to_json
when IOType::JsonPretty
  STDOUT.puts output.as(ProtoBuf::Any).to_pretty_json
end
