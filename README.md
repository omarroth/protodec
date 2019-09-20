# protodec

Command-line tool to encode and decode arbitrary protobuf data.

## Usage

```
$ ./protodec -h
Usage: protodec [arguments]
Command-line decoder for arbitrary protobuf data. Reads from standard input.
    -r, --raw                        STDIN is raw binary data (default)
    -x, --hex                        STDIN is space-separated hexstring
    -d, --decode                     STDIN is Base64-encoded
    -p, --pretty                     Pretty print output
    -h, --help                       Show this help
```

```
$ echo 'CkEKCeOCj+OBn+OBlxDSCSIQWmQ730+N8z8tsp3vp8YJQCoSCAESBzA4MDAwMDAaBQ26sSZEKgsIARIHMDgwMDAwMBXD9UhA' | ./protodec -dp
{
  "1:0": {
    "1:0": "わたし",
    "2:1": 1234,
    "4:2": [
      90,
      100,
      59,
      223,
      79,
      141,
      243,
      63,
      45,
      178,
      157,
      239,
      167,
      198,
      9,
      64
    ],
    "5:3": {
      "1:0": 1,
      "2:1": "0800000",
      "3:2": {
        "1:0": 666.7769775390625
      }
    },
    "5:4": {
      "1:0": 1,
      "2:1": "0800000"
    }
  },
  "2:1": 3.140000104904175
}
```

## Contributing

1. Fork it (<https://github.com/omarroth/protodec/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Omar Roth](https://github.com/omarroth) - creator and maintainer
