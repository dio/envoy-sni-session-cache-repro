#!/usr/bin/env python3

import argparse
import socket
import struct


HOSTS = {
    b"server1.example.com": socket.inet_aton("127.0.0.1"),
    b"server2.example.com": socket.inet_aton("127.0.0.1"),
}


def parse_question(packet):
    offset = 12
    labels = []
    while True:
        length = packet[offset]
        offset += 1
        if length == 0:
            break
        labels.append(packet[offset : offset + length])
        offset += length
    question_end = offset + 4
    query_type, query_class = struct.unpack("!HH", packet[offset:question_end])
    return b".".join(labels).lower(), query_type, query_class, question_end


def response_for(packet):
    if len(packet) < 12:
        return None

    query_id, _, question_count, _, _, _ = struct.unpack("!HHHHHH", packet[:12])
    if question_count != 1:
        return None

    try:
        hostname, query_type, query_class, question_end = parse_question(packet)
    except (IndexError, struct.error):
        return None

    address = HOSTS.get(hostname)
    has_answer = address is not None and query_type == 1 and query_class == 1
    header = struct.pack("!HHHHHH", query_id, 0x8180, 1, int(has_answer), 0, 0)
    question = packet[12:question_end]
    if not has_answer:
        return header + question

    answer = (
        b"\xc0\x0c"
        + struct.pack("!HHIH", 1, 1, 60, len(address))
        + address
    )
    return header + question + answer


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=1053)
    args = parser.parse_args()

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
        server.bind(("127.0.0.1", args.port))
        while True:
            packet, peer = server.recvfrom(4096)
            response = response_for(packet)
            if response is not None:
                server.sendto(response, peer)


if __name__ == "__main__":
    main()
