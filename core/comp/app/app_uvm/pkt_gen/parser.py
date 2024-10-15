#!/bin/python3

#  SPDX-License-Identifier: BSD-3-Clause
#
#  simple pakcet generator. Packet are generated by random walk.
#  In this file is resolving how prototoclols follows.
#
#  Copyright (C) 2022 CESNET
#  Author(s):
#    Radek Iša <isa@cesnet.cz>

from config import json_object_get
from layers import trill
import sys
import scapy.all
import scapy.utils
import scapy.volatile
import scapy.contrib.mpls
import random
import ipaddress
import json


class base_node:
    def __init__(self, name):
        self.name = name

    def name_get(self):
        return self.name

    def protocol_add(self, config):
        return None

    def protocol_next(self, config):
        return {}


#################################
# PAYLOAD protocols
#################################
class Empty(base_node):
    def __init__(self):
        super().__init__("Empty")


class Payload(base_node):
    def __init__(self):
        super().__init__("Payload")

    def protocol_add(self, config):
        return scapy.all.Raw()


class TRILL(base_node):
    def __init__(self):
        super().__init__("TRILL")

    def protocol_add(self, config):
        return trill.Trill(version=0, res=0)

    def protocol_next(self, config):
        if config.trill != 0:
            config.trill -= 1
        proto = {"ETH" : 1}
        return proto


#################################
# L7 protocols
#################################
class ICMPv4(base_node):
    def __init__(self):
        super().__init__("ICMPv4")

    def protocol_add(self, config):
        return scapy.all.ICMP()


class ICMPv6(base_node):
    def __init__(self):
        super().__init__("ICMPv6")

    def protocol_add(self, config):
        return scapy.all.ICMPv6Unknown()


class UDP(base_node):
    def __init__(self):
        super().__init__("UDP")

    def protocol_add(self, config):
        return scapy.all.UDP()

    def protocol_next(self, config):
        proto = {"Empty" : 1, "Payload" : 1}
        cfg_obj = config.object_get([self.name, "weight"])
        if cfg_obj is not None:
            proto.update(cfg_obj)
        return proto


class TCP(base_node):
    def __init__(self):
        super().__init__("TCP")

    def protocol_add(self, config):
        return scapy.all.TCP()

    def protocol_next(self, config):
        proto = {"Empty" : 1, "Payload" : 1}
        proto_weight = config.object_get([self.name, "weight"])
        if proto_weight is not None:
            proto.update(proto_weight)
        return proto


class SCTP(base_node):
    def __init__(self):
        super().__init__("SCTP")

    def protocol_add(self, config):
        return scapy.all.SCTP()

    def protocol_next(self, config):
        proto = {"Empty" : 1, "Payload" : 1}
        cfg_obj = config.object_get([self.name, "weight"])
        if cfg_obj is not None:
            proto.update(cfg_obj)
        return proto


#################################
# IP protocols
#################################
class IPv4(base_node):
    def __init__(self):
        super().__init__("IPv4")

    def protocol_add(self, config):
        src = None
        dst = None

        src_rand = config.object_get([self.name, "values", "src"])
        if src_rand is not None:
            val_range = random.choice(src_rand)
            src_min = int(val_range.get("min"), 0)
            src_max = int(val_range.get("max"), 0)
            src = str(ipaddress.IPv4Address(random.randint(src_min, src_max)))

        dst_rand = config.object_get([self.name, "values", "dst"])
        if dst_rand is not None:
            val_range = random.choice(dst_rand)
            dst_min = int(val_range.get("min"), 0)
            dst_max = int(val_range.get("max"), 0)
            dst = str(ipaddress.IPv4Address(random.randint(dst_min, dst_max)))

        return scapy.all.IP(version=4, src=src, dst=dst)

    def protocol_next(self, config):
        proto = {"Payload" : 1, "Empty" : 1, "ICMPv4" : 1, "UDP" : 1, "TCP" : 1, "SCTP" : 1}
        proto_weight = config.object_get([self.name, "weight"])
        if proto_weight is not None:
            proto.update(proto_weight)
        return proto


class IPv6Ext(base_node):
    def __init__(self):
        super().__init__("IPv6Ext")

    def protocol_add(self, config):
        possible_protocols = [scapy.all.IPv6ExtHdrDestOpt(), scapy.all.IPv6ExtHdrFragment(id=random.randint(0, 2**32-1)), scapy.all.IPv6ExtHdrHopByHop(), scapy.all.IPv6ExtHdrRouting()]
        return random.choice(possible_protocols)

    def protocol_next(self, config):
        proto = {"Payload" : 1, "Empty" : 1, "ICMPv4" : 1, "ICMPv6" : 1, "UDP" : 1, "TCP" : 1, "SCTP" : 1, "IPv6Ext" : 1}
        proto_weight = config.object_get([self.name, "weight"])
        if proto_weight is not None:
            proto.update(proto_weight)
        # Check if it is last generated IPv6Ext
        if config.ipv6ext != 0:
            config.ipv6ext -= 1
        if config.ipv6ext == 0:
            proto["IPv6Ext"] = 0

        return proto


class IPv6(base_node):
    def __init__(self):
        super().__init__("IPv6")

    def protocol_add(self, config):
        src = None
        dst = None

        src_rand = config.object_get([self.name, "values", "src"])
        if src_rand is not None:
            val_range = random.choice(src_rand)
            src_min = int(val_range.get("min"), 0)
            src_max = int(val_range.get("max"), 0)
            src = str(ipaddress.IPv6Address(random.randint(src_min, src_max)))

        dst_rand = config.object_get([self.name, "values", "dst"])
        if dst_rand is not None:
            val_range = random.choice(dst_rand)
            dst_min = int(val_range.get("min"), 0)
            dst_max = int(val_range.get("max"), 0)
            dst = str(ipaddress.IPv6Address(random.randint(dst_min, dst_max)))

        return scapy.all.IPv6(version=6, src=src, dst=dst)

    def protocol_next(self, config):
        proto = {"Payload" : 1, "Empty" : 1, "ICMPv4" : 1, "ICMPv6" : 1, "UDP" : 1, "TCP" : 1, "SCTP" : 1, "IPv6Ext" : 1}
        proto_weight = config.object_get([self.name, "weight"])
        if proto_weight is not None:
            proto.update(proto_weight)
        return proto

#################################
# ETHERNET protocols
#################################


class MPLS(base_node):
    def __init__(self):
        super().__init__("MPLS")

    def protocol_add(self, config):
        return scapy.contrib.mpls.MPLS()

    def protocol_next(self, config):
        proto   = {"IPv4" : 1, "IPv6" : 1, "MPLS" : 1, "Empty" : 1}
        proto_weight = config.object_get([self.name, "weight"])
        if proto_weight is not None:
            proto.update(proto_weight)
        # Check if it is last generated MPLS
        if config.mpls != 0:
            config.mpls -= 1
        if config.mpls == 0:
            proto["MPLS"] = 0

        return proto


class PPP(base_node):
    def __init__(self):
        super().__init__("PPP")

    def protocol_add(self, config):
        return scapy.all.PPPoE()/scapy.all.PPP()

    def protocol_next(self, config):
        proto = {"IPv4" : 1, "IPv6" : 1, "MPLS" : 1, "Empty" : 1}
        proto_weight = config.object_get([self.name, "weight"])
        if proto_weight is not None:
            proto.update(proto_weight)

        return proto


class VLAN(base_node):
    def __init__(self):
        super().__init__("VLAN")

    def protocol_add(self, config):
        possible_protocols = [scapy.all.Dot1Q(), scapy.all.Dot1AD()]
        return random.choice(possible_protocols)

    def protocol_next(self, config):
        proto   = {"IPv4" : 1, "IPv6" : 1, "VLAN" : 1 , "TRILL" : 1, "MPLS" : 1, "Empty" : 1, "PPP" : 1}
        proto_weight = config.object_get([self.name, "weight"])
        if proto_weight is not None:
            proto.update(proto_weight)
        # check if it is last generated VLAN
        if config.vlan != 0:
            config.vlan -= 1
        if config.vlan == 0:
            proto["VLAN"] = 0
        if config.trill == 0:
            proto["TRILL"] = 0

        return proto


class ETH(base_node):
    def __init__(self):
        super().__init__("ETH")

    def protocol_add(self, config):
        return scapy.all.Ether(src=scapy.volatile.RandMAC(), dst=scapy.volatile.RandMAC())

    def protocol_next(self, config):
        proto = {"IPv4" : 1, "IPv6" : 1, "VLAN" : 1, "TRILL" : 1, "MPLS" : 1, "Empty" : 1, "PPP" : 1}
        proto_weight = config.object_get([self.name, "weight"])
        if proto_weight is not None:
            proto.update(proto_weight)

        if config.trill == 0:
            proto["TRILL"] = 0

        return proto


class parser:
    def __init__(self, pcap_file, cfg, seed):
        self.protocols = {"ETH" : ETH(), "VLAN" : VLAN(), "TRILL" : TRILL(), "PPP" : PPP(), "MPLS" : MPLS(), "IPv6" : IPv6(), "IPv6Ext" : IPv6Ext(),
                          "IPv4" : IPv4(), "TCP" : TCP(), "UDP" : UDP(), "ICMPv6" : ICMPv6(), "ICMPv4" : ICMPv4(), "SCTP" : SCTP(),
                          "Payload" : Payload(), "Empty" : Empty()}
        self.pcap_file = scapy.utils.PcapWriter(pcap_file, append=False, sync=True)
        self.cfg = None
        if cfg is not None:
            conf_file = open(cfg)
            json_cfg  = conf_file.read()
            conf_file.close()
            self.cfg = json.loads(json_cfg)
        random.seed(seed)

        pkt_size_min = json_object_get(self.cfg, ["packet", "size_min"])
        if pkt_size_min is not None:
            self.pkt_size_min  = pkt_size_min
        else:
            self.pkt_size_min  = 60

        pkt_err_probability = json_object_get(self.cfg, ["packet", "err_probability"])
        if pkt_err_probability is not None:
            self.pkt_err_probability = pkt_err_probability
        else:
            self.pkt_err_probability = 0

    def __del__(self):
        self.pcap_file.close()

    def gen(self):
        print("This is Null packet generator and shouldn't be used", file=sys.stderr)
        pass

    def proto_weight_get(self, dict_items):
        proto  = []
        weight = []
        for key in dict_items:
            proto.append(key)
            weight.append(dict_items[key])

        return (proto, weight)

    def write(self, packet):
        packet_fuzz = scapy.packet.fuzz(packet)
        packet_wr   = b""
        try:
            packet_wr = packet_fuzz.build()
        except Exception:
            packet_wr = packet.build()

        # GENERATE ERROR PACKETS
        if random.randint(0, 99) < self.pkt_err_probability:
            packet_wr = packet_wr[0:random.randint(0, len(packet_wr))]
        # SET MINIMAL SIZE
        if len(packet_wr) < self.pkt_size_min:
            packet_wr += bytes(self.pkt_size_min - len(packet_wr))
        self.pcap_file.write(packet_wr)
