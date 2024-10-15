#!/bin/python3

#  SPDX-License-Identifier: BSD-3-Clause
#
#  simple pakcet generator. Packet are generated by random walk.
#
#  Copyright (C) 2022 CESNET
#  Author(s):
#    Radek Iša <isa@cesnet.cz>


from parser_rand import parser_rand as Parser_rand
from parser_dfs import parser_dfs as Parser_dfs
import argparse
import time
import enum


class parse_alg(enum.Enum):
    noe  = 'none'
    dfs  = 'dfs'
    rand = 'rand'

    def __str__(self):
        return self.value

    @staticmethod
    def values():
        ret = []
        arg_list = list(parse_alg)
        for it in arg_list:
            ret.append(it.value)
        return ret


def main():
    #parse options
    arg_parser = argparse.ArgumentParser()
    arg_parser.add_argument("-f", "--file_output", type=str,
                            help="Set output file", required=True)
    arg_parser.add_argument("-p", "--packets", type=int,
                            help="number of generated packets", default=20)
    arg_parser.add_argument("-a", "--algorithm", type=parse_alg,
                            help=("parse algorithms possible values [" + ' '.join(parse_alg.values()) + "]"), default="rand")
    arg_parser.add_argument("-s", "--seed", type=int,
                            help="set seed to random generator", default=int(time.time()*1000))
    arg_parser.add_argument("-c", "--conf", type=str,
                            help="Configrutation of random genertor for protocols in JSON", default=None)

    args = arg_parser.parse_args()
    print("SEED      : " + f'{args.seed}')
    print("ALGORITHM : " + f'{args.algorithm}')

    #args.seed = 1667909888.37288 ./pkt_gen.py -f test.pcap -p 189 result in error
    gen = parser(args.file_output, args.conf, args.seed)

    if (args.algorithm == parse_alg.rand):
        gen = Parser_rand(args.file_output, args.conf, args.seed, args.packets)
    if (args.algorithm == parse_alg.dfs):
        gen = Parser_dfs(args.file_output, args.conf, args.seed)

    #run generator
    gen.gen()


if __name__ == "__main__":
    main()
