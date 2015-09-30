import dpkt
import socket
import time

counter=0
ipcounter=0
tcpcounter=0
udpcounter=0

filename='../secure_data/dump_flow.pcap'

while True:
    tmp1 = None
    tmp2 = None
    for ts, pkt in dpkt.pcap.Reader(open(filename,'r')):
        counter += 1
        ip = dpkt.ip.IP(pkt[16:])

        if ip.p!=dpkt.ip.IP_PROTO_UDP:
           raise Exception()

        udp = ip.data

        if tmp1 is None:
            tmp1 = bytes(udp.data)
            continue

        if tmp2 is None:
            tmp2 = bytes(udp.data)
            continue

        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM) # UDP
        sock.sendto(tmp1, ("0.0.0.0", 9996))
        # time.sleep(0.05)

        # exit(0)

        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM) # UDP
        sock.sendto(udp.data, ("0.0.0.0", 9996))
        # time.sleep(0.05)

        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM) # UDP
        sock.sendto(tmp2, ("0.0.0.0", 9996))
        if divmod(counter, 300)[1] == 0:
            time.sleep(1)
            print counter
        tmp1 = tmp2 = None
    break