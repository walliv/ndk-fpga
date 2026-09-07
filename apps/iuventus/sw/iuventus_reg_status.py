#!/usr/bin/env python3

import sys

from argparse import ArgumentParser

import nfb
import ofm.comp.dma.iuventus as ira
from  ofm.comp.debug.data_logger.data_logger import DataLogger

def parseParams():
    parser = ArgumentParser(description =
        """DMA Iuventus control and configuration script""",
    )

    access = parser.add_argument_group('card access arguments')
    access.add_argument('-d', '--device', default=nfb.libnfb.Nfb.default_dev_path,
                        metavar='device', help = "Index of a NFB device")
    access.add_argument('-i', '--index', type=int, metavar='index', default=0, help = "Index of Data Logger in the Device Tree")

    common = parser.add_argument_group('component control')
    common.add_argument('--stop', action='store_true', help = "Stops generator")
    common.add_argument('-e', '--show_errs', action='store_true', help = "Prints error mask")
    common.add_argument('-c', '--clr_errs', action='store_true', help = "Clears error mask")
    common.add_argument('-R', '--cntr_rst', action='store_true', help = "Resets counters")
    common.add_argument('--rst', action='store_true', help = "Resets the DMA Iuventus component")

    args = parser.parse_args()
    return args


if __name__ == "__main__":
    args = parseParams()
    dma_ctrl = ira.DMAIuventusRegAccess(dev=args.device, index=args.index)
    dlogger = DataLogger(dev=args.device, index=args.index)

    if (args.rst):
        dlogger.rst()
    elif (args.cntr_rst):
        dma_ctrl.rst_cntrs()
    elif (args.clr_errs):
        dma_ctrl.clr_err_mask()
        sys.exit(0)

    if (args.stop):
        dma_ctrl.disable()
        print("Component disabled")
        sys.exit(0)

    conf = dma_ctrl.get_configuration()
    print(conf)

    if args.show_errs:
        print(f"Error mask:")
        print(conf.process_error_mask())
