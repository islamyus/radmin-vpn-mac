#!/usr/bin/env python3
"""Offline PCAPNG -> private TCP streams + a redacted structural summary.

No external dependencies, network requests, or execution of captured content.
Handles the supplied PktMon capture whose Ethernet IDB contains raw 802.11.
Original files remain untouched. Output directories must be new.
"""
import argparse
import collections
import json
import pathlib
import struct


def option_values(data, endian):
    offset = 0
    while offset + 4 <= len(data):
        code, length = struct.unpack_from(endian + "HH", data, offset)
        offset += 4
        if code == 0:
            return
        if offset + length > len(data):
            raise ValueError("Truncated PCAPNG option")
        yield code, data[offset:offset + length]
        offset += (length + 3) & ~3


def pcapng_packets(data):
    offset, endian, interfaces = 0, None, []
    while offset < len(data):
        if len(data) - offset < 12:
            raise ValueError("Truncated PCAPNG block")
        if data[offset:offset + 4] == b"\x0a\x0d\x0d\x0a":
            bom = data[offset + 8:offset + 12]
            endian = {b"\x4d\x3c\x2b\x1a": "<", b"\x1a\x2b\x3c\x4d": ">"}.get(bom)
            if endian is None:
                raise ValueError("Invalid PCAPNG byte order")
            interfaces = []
        if endian is None:
            raise ValueError("Missing PCAPNG section header")
        kind, length = struct.unpack_from(endian + "II", data, offset)
        if length < 12 or length % 4 or length > len(data) - offset:
            raise ValueError("Invalid PCAPNG block size")
        block = data[offset:offset + length]
        if struct.unpack_from(endian + "I", block, length - 4)[0] != length:
            raise ValueError("PCAPNG block trailer mismatch")
        if kind == 1:
            if length < 20:
                raise ValueError("Short interface block")
            linktype, _, snaplen = struct.unpack_from(endian + "HHI", block, 8)
            resolution, adjustment = 1e-6, 0
            for code, value in option_values(block[16:-4], endian):
                if code == 9 and len(value) == 1:
                    resolution = 2 ** -(value[0] & 127) if value[0] & 128 else 10 ** -value[0]
                if code == 14 and len(value) == 8:
                    adjustment = struct.unpack(endian + "q", value)[0]
            interfaces.append((linktype, snaplen, resolution, adjustment))
        if kind == 6:
            if length < 32:
                raise ValueError("Short enhanced packet block")
            interface, high, low, caplen, wirelen = struct.unpack_from(endian + "IIIII", block, 8)
            if interface >= len(interfaces) or caplen > length - 32 or caplen > wirelen:
                raise ValueError("Invalid enhanced packet bounds")
            linktype, snaplen, resolution, adjustment = interfaces[interface]
            if snaplen and caplen > snaplen:
                raise ValueError("Captured length exceeds interface snaplen")
            yield (((high << 32) | low) * resolution + adjustment, linktype, block[28:28 + caplen])
        offset += length


def ethernet_frame(raw, linktype):
    # Require a structurally valid 802.11 data header and LLC at the exact
    # computed payload offset. Searching arbitrary bytes for an LLC pattern
    # would misclassify encrypted/aggregated packets.
    if len(raw) >= 24:
        control = int.from_bytes(raw[:2], "little")
        if control & 3 == 0 and (control >> 2) & 3 == 2 and not control & 0x4000:
            ds = (control >> 8) & 3
            header = 30 if ds == 3 else 24
            subtype = (control >> 4) & 15
            if subtype & 8:
                if len(raw) < header + 2 or raw[header] & 0x80:
                    return None, "unsupported-amsdu-or-short"
                header += 2
                if control & 0x8000:
                    header += 4
            if raw[header:header + 6] == b"\xaa\xaa\x03\x00\x00\x00" and len(raw) >= header + 8:
                a1, a2, a3 = raw[4:10], raw[10:16], raw[16:22]
                destination, source = ((a1, a2), (a3, a2), (a1, a3), (a3, raw[24:30]))[ds]
                return destination + source + raw[header + 6:], "802.11-llc"
    if linktype == 1 and len(raw) >= 14 and raw[12:14] in (b"\x08\x00", b"\x08\x06", b"\x86\xdd"):
        return raw, "ethernet"
    return None, "unsupported-link-frame"


def ipv4_tcp(frame):
    if len(frame) < 34 or frame[12:14] != b"\x08\x00":
        return None
    ip = frame[14:]
    header = (ip[0] & 15) * 4
    total = int.from_bytes(ip[2:4], "big")
    if ip[0] >> 4 != 4 or header < 20 or total > len(ip) or total < header + 20 or ip[9] != 6:
        return None
    if int.from_bytes(ip[6:8], "big") & 0x3fff:
        return None  # Fragment reassembly is outside this analyzer.
    tcp = ip[header:total]
    tcp_header = (tcp[12] >> 4) * 4
    if tcp_header < 20 or tcp_header > len(tcp):
        return None
    source = ".".join(map(str, ip[12:16]))
    destination = ".".join(map(str, ip[16:20]))
    source_port, destination_port, seq = struct.unpack_from("!HHI", tcp)
    return ((source, source_port, destination, destination_port), seq, tcp[13], tcp[tcp_header:])


def reassemble(packets):
    syn = next((seq for _, seq, flags, _ in packets if flags & 2), None)
    chunks = [(seq, payload) for _, seq, _, payload in packets if payload]
    if not chunks:
        return b"", syn is not None, 0, 0
    baseline = (syn + 1) & 0xffffffff if syn is not None else chunks[0][0]
    segments = sorted((((seq - baseline) & 0xffffffff, value) for seq, value in chunks), key=lambda item: item[0])
    stream = bytearray()
    duplicates = 0
    for position, payload in segments:
        if position > len(stream):
            return bytes(stream), syn is not None, position - len(stream), duplicates
        overlap = min(len(payload), len(stream) - position)
        if stream[position:position + overlap] != payload[:overlap]:
            raise ValueError("Conflicting TCP overlap")
        if overlap == len(payload):
            duplicates += 1
        stream.extend(payload[overlap:])
        if len(stream) > 16 * 1024 * 1024:
            raise ValueError("TCP stream exceeds local analysis limit")
    return bytes(stream), syn is not None, 0, duplicates


def record_lengths(stream):
    offset, lengths = 0, []
    while len(stream) - offset >= 4:
        size = int.from_bytes(stream[offset:offset + 4], "big")
        if size > 1_048_576:
            return lengths, len(stream) - offset, "record-limit-or-midstream"
        if size > len(stream) - offset - 4:
            return lengths, len(stream) - offset, "incomplete-record"
        lengths.append(size)
        offset += size + 4
    return lengths, len(stream) - offset, None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, required=True, help="A new private directory")
    parser.add_argument("--port", type=int, default=17301, help="Observed candidate control port, not process attribution")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False, mode=0o700)
    data = args.capture.read_bytes()
    flows = collections.defaultdict(list)
    formats = collections.Counter()
    timestamps = []
    with (args.output / "normalized-ethernet.pcap").open("xb") as output:
        output.write(struct.pack("<IHHIIII", 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1))
        for timestamp, linktype, raw in pcapng_packets(data):
            timestamps.append(timestamp)
            frame, form = ethernet_frame(raw, linktype)
            formats[form] += 1
            if frame is None:
                continue
            microseconds = round(timestamp * 1_000_000)
            output.write(struct.pack("<IIII", microseconds // 1_000_000, microseconds % 1_000_000, len(frame), len(frame)))
            output.write(frame)
            packet = ipv4_tcp(frame)
            if packet:
                key, sequence, flags, payload = packet
                if args.port in (key[1], key[3]):
                    flows[key].append((timestamp, sequence, flags, payload))
    if not timestamps:
        raise ValueError("No captured packets")
    summary = {"packetCount": len(timestamps), "durationSeconds": round(max(timestamps) - min(timestamps), 6),
               "frameFormats": dict(formats), "candidatePort": args.port, "streams": []}
    for index, (key, packets) in enumerate(flows.items(), start=1):
        stream, has_syn, gap, duplicates = reassemble(packets)
        lengths, pending, error = record_lengths(stream)
        name = f"stream-{index:02d}"
        (args.output / (name + ".bin")).write_bytes(stream)
        item = {"id": name, "direction": "server-to-client" if key[1] == args.port else "client-to-server",
                "clientPort": key[3] if key[1] == args.port else key[1],
                "hasSYN": has_syn, "packetCount": len(packets), "streamBytes": len(stream),
                "gapBytes": gap, "duplicateSegments": duplicates, "recordBodyLengths": lengths,
                "pendingBytes": pending, "framingError": error,
                "startsWithVersion3": stream.startswith(bytes.fromhex("0000000403000000"))}
        summary["streams"].append(item)
    (args.output / "summary-redacted.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
