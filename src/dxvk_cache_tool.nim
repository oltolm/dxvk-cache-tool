# This is just an example to get you started. A typical binary package
# uses this file as the main entry point of the application.

import os
import strutils
import tables
import streams
import sha1

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

type Entry = object
  header: EntryHeader
  hash: array[0..HashSize-1, uint8]
  data: seq[uint8]

proc isValid(entry: ref Entry): bool =
  return sha1.compute(entry.data) == entry.hash

type Header = object
  magic: array[0..3, uint8]
  version: uint32
  entrySize: uint32

proc newConfig(): Config =
  return Config(output: "output.dxvk-cache")

proc readHeader(fs: FileStream): Header =
  var header: Header
  fs.read(header.magic)
  header.version = fs.readUint32
  header.entrySize = fs.readUint32
  return header

proc readUint24(a: array[0..2, uint8]): uint32 =
  return uint32(a[0]) + uint32(a[1]) shl 8 + uint32(a[2]) shl 16

proc readEntry(fs: FileStream): ref Entry =
  var header: EntryHeader
  header.stageMask = fs.readUint8
  var entrySize: array[0..2, uint8]
  fs.read(entrySize)
  header.entrySize = readUint24(entrySize)
  var entry = new(Entry)
  entry.header = header
  fs.read(entry.hash)
  newSeq(entry.data, header.entrySize)
  discard fs.readData(entry.data[0].addr, entry.data.len)
  return entry

proc writeHeader(fs: FileStream, header: Header) =
  fs.write(header.magic)
  fs.write(header.version)
  fs.write(header.entrySize)

proc writeEntry(fs: FileStream, entry: ref Entry) =
  fs.write(entry.header.stageMask)
  fs.write(entry.header.entrySize) # TODO: write 3 bytes!
  fs.write(entry.hash)
  fs.write(entry.data)

proc main(): int =
  if os.commandLineParams().len == 0:
    raiseAssert("need at least one file")
  var config = newConfig()
  for file in os.commandLineParams():
    config.files.add(file)
  write(stderr, "Merging files");
  for path in config.files:
    write(stdout, format(" $#", path));
  writeLine(stdout, "");

  var entries = newTable[string, ref Entry]()

  for i,path in config.files:
    var (_, _, ext) = splitFile(path)
    if ext != ".dxvk-cache":
      raiseAssert("File extension mismatch: expected .dxvk-cache")
  
    var fs = openFileStream(path)
    defer: fs.close

    var header = readHeader(fs)
    if header.magic != MagicString:
      raiseAssert("Magic string mismatch")
    if config.version == 0:
      config.version = header.version
      config.entrySize = header.entrySize
      stdout.writeLine(format("Detected state cache version $#", header.version))
      if header.version != 8:
        raiseAssert("only version 8 is supported, exiting")
    stdout.writeLine(format("Merging $# ($#/$#)...", path, i+1, config.files.len))
    var omitted = 0
    var entriesLen = entries.len
    while true:
      var entry = readEntry(fs)
      if entry.isValid:
        entries[entry.hash.toHex] = entry
      else:
        omitted.inc
      if fs.atEnd:
        break

    stdout.writeLine(format("$# new entries", entries.len - entriesLen))
    if omitted > 0:
      stdout.writeLine(format("$# entries are omitted as invalid", omitted))

  if entries.len == 0:
    raiseAssert("No valid state cache entries found")
  
  var fs = openFileStream(config.output)
  defer: fs.close
  stdout.writeLine(format("Writing $# entries to file $#", entries.len,
   config.output))
  var header = Header(magic: MagicString, version: config.version, entrySize: config.entrySize)
  writeHeader(fs, header)
  for entry in entries.values:
    writeEntry(fs, entry)
  stdout.writeLine("Finished")

when isMainModule:
  try:
    discard main()
  except:
    stderr.writeLine(format("error, exiting: $#", getCurrentExceptionMsg()))
