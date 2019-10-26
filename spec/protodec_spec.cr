require "./spec_helper"

describe Protodec do
  it "decodes Base64 data" do
    input = "4qmFsgIsEhhVQ0NqOTU2SUY2MkZiVDdHb3VzemFqOXcaEEVnbGpiMjF0ZFc1cGRIaz0"
    output = input.strip
      .try { |i| URI.decode_www_form(i) }
      .try { |i| URI.decode_www_form(i) }
      .try { |i| Base64.decode(i) }
      .try { |i| IO::Memory.new(i) }
      .try { |i| Protodec::Any.parse(i) }

    output["80226972:0:embedded"]["2:0:string"].should eq("UCCj956IF62FbT7Gouszaj9w")
    output["80226972:0:embedded"]["3:1:base64"]["2:0:string"].should eq("community")
  end

  it "encodes JSON object" do
    object = Protodec::Any.cast_json({
      "80226972:0:embedded" => {
        "2:0:string" => "UCCj956IF62FbT7Gouszaj9w",
        "3:1:base64" => {
          "2:0:string" => "community",
        },
      },
    })

    Base64.urlsafe_encode(Protodec::Any.from_json(object), padding: false).should eq("4qmFsgIsEhhVQ0NqOTU2SUY2MkZiVDdHb3VzemFqOXcaEEVnbGpiMjF0ZFc1cGRIaz0")
  end
end
