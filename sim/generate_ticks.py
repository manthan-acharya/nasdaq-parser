#!/usr/bin/env python3
# Generates raw binary packet stream containing mock Ethernet/IP/UDP/MoldUDP64/ITCH-5.0 frames.

import struct

def calculate_ip_checksum(header):
    if len(header) % 2 == 1:
        header += b'\x00'
    words = struct.unpack('>%dH' % (len(header) // 2), header)
    checksum = sum(words)
    while checksum >> 16:
        checksum = (checksum & 0xFFFF) + (checksum >> 16)
    return (~checksum) & 0xFFFF

def make_itch_add_order(order_ref_id, side, shares, ticker, price_x10000, locate=1):
    # ITCH-5.0 Add Order (Type 'A') Message (36-byte payload)
    ticker_padded = ticker.ljust(8)[:8].encode('ascii')
    side_char = ord(side)
    
    msg = struct.pack(
        '>HcHH6sQcI8sI',
        36,
        b'A',
        locate,
        1,
        b'\x00\x00\x00\x07\x5b\xcd',
        order_ref_id,
        bytes([side_char]),
        shares,
        ticker_padded,
        price_x10000
    )
    return msg

def make_itch_execute(order_ref_id, shares, locate=1):
    # ITCH-5.0 Order Executed (Type 'E') Message (31-byte payload)
    msg = struct.pack(
        '>HcHH6sQIQ',
        31,
        b'E',
        locate,
        1,
        b'\x00\x00\x00\x07\x5b\xce',
        order_ref_id,
        shares,
        9876543210
    )
    return msg

def make_itch_cancel(order_ref_id, shares, locate=1):
    # ITCH-5.0 Order Cancel (Type 'X') Message (23-byte payload)
    msg = struct.pack(
        '>HcHH6sQI',
        23,
        b'X',
        locate,
        1,
        b'\x00\x00\x00\x07\x5b\xcf',
        order_ref_id,
        shares
    )
    return msg

def make_itch_delete(order_ref_id, locate=1):
    # ITCH-5.0 Order Delete (Type 'D') Message (19-byte payload)
    msg = struct.pack(
        '>HcHH6sQ',
        19,
        b'D',
        locate,
        1,
        b'\x00\x00\x00\x07\x5b\xd0',
        order_ref_id
    )
    return msg

def make_itch_replace(original_order_ref_id, new_order_ref_id, shares, price_x10000, locate=1):
    # ITCH-5.0 Order Replace (Type 'U') Message (35-byte payload)
    msg = struct.pack(
        '>HcHH6sQQII',
        35,
        b'U',
        locate,
        1,
        b'\x00\x00\x00\x07\x5b\xd1',
        original_order_ref_id,
        new_order_ref_id,
        shares,
        price_x10000
    )
    return msg

def create_udp_packet(payload):
    # Wraps raw payload in standard Ethernet, IPv4, and UDP headers
    eth_dst = b'\x00\x0a\x35\x0d\x21\x51'
    eth_src = b'\x00\x0a\x35\x0d\x21\x50'
    eth_type = b'\x08\x00'
    eth_header = eth_dst + eth_src + eth_type
    
    ip_ver_ihl = 0x45
    ip_tos = 0x00
    ip_id = 0x1234
    ip_flags_frag = 0x4000
    ip_ttl = 64
    ip_proto = 17
    ip_src = b'\xc0\xa8\x01\x64'
    ip_dst = b'\xc0\xa8\x01\xc8'
    
    udp_len = 8 + len(payload)
    ip_len = 20 + udp_len
    
    ip_header_no_chk = struct.pack(
        '>BBHHHBBH4s4s',
        ip_ver_ihl, ip_tos, ip_len, ip_id, ip_flags_frag,
        ip_ttl, ip_proto, 0, ip_src, ip_dst
    )
    ip_chk = calculate_ip_checksum(ip_header_no_chk)
    
    ip_header = struct.pack(
        '>BBHHHBBH4s4s',
        ip_ver_ihl, ip_tos, ip_len, ip_id, ip_flags_frag,
        ip_ttl, ip_proto, ip_chk, ip_src, ip_dst
    )
    
    udp_src_port = 12345
    udp_dst_port = 15555
    udp_chk = 0x0000
    
    udp_header = struct.pack(
        '>HHHH',
        udp_src_port, udp_dst_port, udp_len, udp_chk
    )
    
    return eth_header + ip_header + udp_header + payload

def create_moldudp64_packet(seq_num, itch_msgs):
    # Wraps ITCH messages in a MoldUDP64 packet header
    session = b'SESS0001  '
    msg_count = len(itch_msgs)
    
    mold_header = struct.pack('>10sQH', session, seq_num, msg_count)
    mold_payload = b''.join(itch_msgs)
    return mold_header + mold_payload

def main():
    print("Generating HFT network tick stream...")
    
    # Sequence of ITCH messages for LOB simulation verification:
    # 1. Add Bid Order AAPL at 150.2500 (Ref ID: 100001)
    # 2. Add Ask Order AAPL at 150.3000 (Ref ID: 100002)
    # 3. Add Bid Order AAPL at 150.2600 (Ref ID: 100003) - Updates Best Bid!
    # 4. Execute Bid Order AAPL at 150.2600 partially (Ref ID: 100003, 200 shares)
    # 5. Delete Bid Order AAPL (Ref ID: 100003) - Reverts Best Bid to 150.2500!
    # 6. Cancel Ask Order AAPL (Ref ID: 100002, 100 shares)
    # 7. Replace Bid Order AAPL (Ref ID: 100001 replaced by 100004, at 150.2700, 600 shares) - Updates Best Bid!
    
    seq_num = 1
    
    itch_packet_1 = [
        make_itch_add_order(100001, 'B', 500, 'AAPL', 1502500),
        make_itch_add_order(100002, 'S', 300, 'AAPL', 1503000)
    ]
    mold_1 = create_moldudp64_packet(seq_num, itch_packet_1)
    pkt_1 = create_udp_packet(mold_1)
    seq_num += len(itch_packet_1)
    
    itch_packet_2 = [
        make_itch_add_order(100003, 'B', 400, 'AAPL', 1502600)
    ]
    mold_2 = create_moldudp64_packet(seq_num, itch_packet_2)
    pkt_2 = create_udp_packet(mold_2)
    seq_num += len(itch_packet_2)
    
    itch_packet_3 = [
        make_itch_execute(100003, 200),
        make_itch_delete(100003)
    ]
    mold_3 = create_moldudp64_packet(seq_num, itch_packet_3)
    pkt_3 = create_udp_packet(mold_3)
    seq_num += len(itch_packet_3)
    
    itch_packet_4 = [
        make_itch_cancel(100002, 100)
    ]
    mold_4 = create_moldudp64_packet(seq_num, itch_packet_4)
    pkt_4 = create_udp_packet(mold_4)
    seq_num += len(itch_packet_4)
    
    itch_packet_5 = [
        make_itch_replace(100001, 100004, 600, 1502700)
    ]
    mold_5 = create_moldudp64_packet(seq_num, itch_packet_5)
    pkt_5 = create_udp_packet(mold_5)
    
    # Write packets prefixed with 32-bit length for C++ DPI-C harness ingestion
    with open('raw_packets.bin', 'wb') as f:
        for pkt in [pkt_1, pkt_2, pkt_3, pkt_4, pkt_5]:
            f.write(struct.pack('<I', len(pkt)))
            f.write(pkt)
            
    print(f"Success! Generated raw_packets.bin (5 packets containing ITCH updates).")

if __name__ == '__main__':
    main()
