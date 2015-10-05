import sys
import dpkt
import socket
import time
import struct
from datetime import datetime


def main(filename):
    with open(filename, 'r') as flow_file:
        for counter, (_, pkt) in enumerate(dpkt.pcap.Reader(flow_file)):
            ip = dpkt.ip.IP(pkt[16:])
            assert ip.p == dpkt.ip.IP_PROTO_UDP
            udp_raw = bytes(ip.data.data)

            bras_uptime_sec = socket.ntohl(struct.unpack('I', udp_raw[4:8])[0])/1000.0

            if counter == 0:
                time_diff = time.time() - bras_uptime_sec
                package_time_by_uptime = lambda x: x + time_diff

            while time.time() < package_time_by_uptime(bras_uptime_sec):
                time.sleep(0.1)

            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.sendto(udp_raw, ("0.0.0.0", 9996))
            time.sleep(0.01)
            if counter % 300 == 0:
                print('{0}\t{1}'.format(datetime.now().strftime('%H:%M:%S'), counter))


if __name__ == '__main__':
    assert len(sys.argv) == 2, u'Usage: nf_gen.py <pcap netflow dump file>'
    main(sys.argv[1])
