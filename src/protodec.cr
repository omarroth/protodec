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

require "option_parser"
require "./protodec/utils"

CURRENT_BRANCH  = {{ "#{`git branch | sed -n '/\* /s///p'`.strip}" }}
CURRENT_COMMIT  = {{ "#{`git rev-list HEAD --max-count=1 --abbrev-commit`.strip}" }}
CURRENT_VERSION = {{ "#{`git describe --tags --abbrev=0`.strip}" }}

SOFTWARE = {
  "name"    => "protodec",
  "version" => "#{CURRENT_VERSION}-#{CURRENT_COMMIT}",
  "branch"  => "#{CURRENT_BRANCH}",
}

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
  output = Protodec::Any.parse(IO::Memory.new(Base64.decode(URI.decode_www_form(URI.decode_www_form(STDIN.gets_to_end.strip)))))
when IOType::Hex
  array = STDIN.gets_to_end.strip.split(/[- ,]+/).map &.to_i(16).to_u8
  output = Protodec::Any.parse(IO::Memory.new(Slice.new(array.size) { |i| array[i] }))
when IOType::Raw
  output = Protodec::Any.parse(IO::Memory.new(STDIN.gets_to_end))
when IOType::Json, IOType::JsonPretty
  output = IO::Memory.new
  Protodec::Any.from_json(JSON.parse(STDIN), output)
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
  STDOUT.puts output.as(Protodec::Any).to_json
when IOType::JsonPretty
  STDOUT.puts output.as(Protodec::Any).to_pretty_json
end
