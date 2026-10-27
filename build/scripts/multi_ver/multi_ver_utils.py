# SPDX-License-Identifier: BSD-3-Clause
# Copyright (C) 2025 CESNET z. s. p. o.
# Author(s): Jan Kubalek <xkubal11@stud.fit.vutbr.cz>
#            Ondrej Schwarz <ondrejschwarz@cesnet.cz>

import copy
from random import randint


# RANDOMLY reduce number of combination to a certain percentage
def reduce_combinations(combinations, reduction_perc=100):
    if reduction_perc >= 100:
        return combinations

    items = len(combinations)
    new_items = items * reduction_perc // 100
    if new_items < 1:
        new_items = 1

    comb = list(combinations.keys())
    new_comb = dict()
    for i in range(new_items):
        new_item_key = comb.pop(randint(0, len(comb) - 1))
        new_comb[new_item_key] = combinations[new_item_key]

    return new_comb


# Modify setting variable
# Raises ValueError when the combination cannot be created as written
def create_setting_from_combination(settings, combination):
    if isinstance(combination, str):
        raise ValueError("Combination \"{}\" is a string, not a tuple. Add a trailing comma.".format(combination))
    # Deep copy, so the merged dicts below do not change the settings
    s = copy.deepcopy(settings["default"])
    for c in combination:
        if c not in settings.keys():
            raise ValueError("Combination \"{}\" contains unknown setting name \"{}\"!".format(combination, c))
        for i in settings[c].keys(): # load modified values
            # if parameter is a dict then merge it
            if i in ("__core_params__", "__cocotb_params__"):
                s.setdefault(i, {}).update(settings[c][i])
            # or it is string
            elif i not in s.keys():
                raise ValueError("Parameter \"{}\" is present in setting \"{}\" but not in setting \"default\"!".format(i, c))
            else:
                s[i] = settings[c][i]
    return s


# Combinations of a SETTINGS dictionary, by name; removes the "_combinations_*" entries from it
def expand_combinations(settings, run_percentage=None):
    combinations = dict()

    if "_combinations_" in settings.keys():
        # User defined combinations
        if type(settings["_combinations_"]) is dict:
            combinations = settings["_combinations_"]
        if type(settings["_combinations_"]) is tuple:
            for it, comb in enumerate(settings["_combinations_"]):
                combinations[f"test_name_{it}"] = comb

        del settings["_combinations_"]

    else:
        # Default combinations
        for key in settings.keys():
            combinations[key] = (key, )

    if run_percentage:
        # Randomly reduce number of combinations based on command argument
        combinations = reduce_combinations(combinations, int(run_percentage))
        del settings["_combinations_run_percentage_"]
    elif "_combinations_run_percentage_" in settings.keys():
        # Randomly reduce number of combinations based on SETTINGS
        combinations = reduce_combinations(combinations, settings["_combinations_run_percentage_"])
        del settings["_combinations_run_percentage_"]

    return combinations


# Environment of the cocotb test: each key K of "__cocotb_params__" (removed from the setting) becomes COCOTB_K
def cocotb_params_env(setting):
    return {f"COCOTB_{name}": value for name, value in setting.pop("__cocotb_params__", {}).items()}
