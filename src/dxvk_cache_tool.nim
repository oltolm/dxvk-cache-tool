import os
import sha1
import streams
import strutils
import tables
import parseopt

const Version = "0.0.2"

const HashSize = 20

const MagicString: array[0..3, uint8] = [uint8('D'), uint8('X'), uint8('V'), uint8('K')]

type Config = ref object
  files: seq[string]
  output: string
  version: uint32
  entrySize: uint32

type EntryHeader = object
  stageMask: uint8
  entrySize: uint32

type Entry = ref object
  header: EntryHeader
  hash: array[0..HashSize-1, uint8]
  data: seq[uint8]

proc isValid(entry: Entry): bool =
  return sha1.compute(entry.data) == entry.hash

type Header = object
  magic: array[0..3, uint8]
  version: uint32
  entrySize: uint32

proc newConfig(): Config =
  return Config(output: "output.dxvk-cache")

proc readHeader(fs: FileStream): Header =
  var header: Header
  read(fs, header.magic)
  header.version = fs.readUint32
  header.entrySize = fs.readUint32
  return header

proc readUint24(fs: FileStream): uint32 =
  var a: array[0..2, uint8]
  read(fs, a)
  return uint32(a[0]) + uint32(a[1]) shl 8 + uint32(a[2]) shl 16

proc writeUint24(fs: FileStream, n: uint32) =
  var p: array[0..2, uint8]
  p[0] = uint8(n)
  p[1] = uint8(n shr 8)
  p[2] = uint8(n shr 16)
  write(fs, p)

proc readEntry(fs: FileStream): Entry =
  var header: EntryHeader
  header.stageMask = fs.readUint8
  header.entrySize = fs.readUint24
  var entry = Entry(header: header)
  read(fs, entry.hash)
  newSeq(entry.data, header.entrySize)
  let n = readData(fs, entry.data[0].addr, entry.data.len)
  if (n != entry.data.len):
    writeLine(stderr, format("reading entry data, expected: $#, actual: $#", entry.data.len, n))
  return entry

proc writeHeader(fs: FileStream, header: Header) =
  write(fs, header.magic)
  write(fs, header.version)
  write(fs, header.entrySize)

proc writeEntry(fs: FileStream, entry: Entry) =
  write(fs, entry.header.stageMask)
  writeUint24(fs, entry.header.entrySize)
  write(fs, entry.hash)
  writeData(fs, entry.data[0].addr, entry.data.len)

proc main(output: string, files: seq[string]): int =
  var config = newConfig()
  if (output != ""): config.output = output
  for file in files:
    config.files.add(file)
  write(stderr, "Merging files");
  for path in config.files:
    write(stdout, format(" $#", path));
  writeLine(stdout, "");

  var entries = newTable[string, Entry]()

  for i, path in config.files:
    var (_, _, ext) = splitFile(path)
    doAssert(ext == ".dxvk-cache", "File extension mismatch: expected .dxvk-cache")
  
    var fs = openFileStream(path)
    defer: close(fs)

    var header = readHeader(fs)
    doAssert(header.magic == MagicString, "Magic string mismatch")
    if config.version == 0:
      config.version = header.version
      config.entrySize = header.entrySize
      writeLine(stdout, format("Detected state cache version $#", header.version))
      doAssert(header.version == 8, "only version 8 is supported, exiting")
    writeLine(stdout, format("Merging $# ($#/$#)...", path, i+1, config.files.len))
    var omitted = 0
    var entriesLen = entries.len
    while true:
      var entry = readEntry(fs)
      if entry.isValid():
        entries[entry.hash.toHex] = entry
      else:
        omitted.inc()
        writeLine(stderr, format("expected: $#, actual: $#", entry.hash.toHex, sha1.compute(entry.data).toHex))
      if atEnd(fs):
        break

    writeLine(stdout, format("$# new entries", entries.len - entriesLen))
    if omitted > 0:
      writeLine(stdout, format("$# entries are omitted as invalid", omitted))

  doAssert(entries.len != 0, "No valid state cache entries found")
  
  var fs = openFileStream(config.output, fmWrite)
  defer: close(fs)
  writeLine(stdout, format("Writing $# entries to file $#", entries.len,
   config.output))
  var header = Header(magic: MagicString, version: config.version, entrySize: config.entrySize)
  writeHeader(fs, header)
  for entry in entries.values:
    writeEntry(fs, entry)
  writeLine(stdout, "Finished")

let doc = """
dxvk_cache_tool [OPTIONS] <FILE>...

OPTIONS:    
        -oFILE, --output FILE   Set output file name
        -h, --help              Display help and exit
        -V, --version           Output version information and exit
"""

proc writeVersion() =
  writeLine(stdout, format("dxvk_cache_tool $#", Version))
  quit(0)

proc writeHelp() =
  writeLine(stdout, doc)
  quit(0)

when isMainModule:
  try:
    var output: string
    var files: seq[string] = @[]
    var p = initOptParser(shortNoVal = {'h', 'V'}, longNoVal = @["help", "version"])
    for kind, key, val in p.getopt():
      case kind
      of cmdArgument:
        files.add(key)
      of cmdEnd: assert(false)
      of cmdLongOption, cmdShortOption:
        case key
        of "help", "h":
          writeHelp()
        of "version", "V":
          writeVersion()
        of "output", "o":
          output = val
    if (files.len == 0):
      writeHelp()
    discard main(output, files)
  except:
    writeLine(stderr, format("error, exiting: $#", getCurrentExceptionMsg()))
    quit(1)
