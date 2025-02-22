#!/usr/bin/env python
# -*- coding: utf-8 -*-
# encoding=utf-8 vi:ts=4:sw=4:expandtab:ft=python

import re
import sys
import json

def analyze(model_name, batch_size, log_file, res_log_file):
    gpu_ids_pat = re.compile(r"GPU (.*):")
    time_pat = re.compile(r"time: (.*), data_time")

    logs = open(log_file).readlines()
    logs = ";".join(logs)
    gpu_ids_res = gpu_ids_pat.findall(logs)
    time_res = time_pat.findall(logs)

    fail_flag = 0
    run_mode = ""
    gpu_num = 0
    ips = 0

    if gpu_ids_res == [] or time_res == []:
        fail_flag = 1
    else:
        gpu_num = int(gpu_ids_res[0][-1])
        run_mode = "sp" if gpu_num == 1 else "mp"

        skip_num = 4
        total_time = 0
        for i in range(skip_num, len(time_res)):
            total_time += float(time_res[i])
        avg_time = total_time / (len(time_res) - skip_num)
        ips = float(batch_size) * round(1 / avg_time, 3)

    info = {"log_file": log_file, "model_name": model_name, "mission_name": "图像生成",
            "direction_id": 0, "run_mode": run_mode, "index": 1, "gpu_num": gpu_num,
            "FINAL_RESULT": ips, "JOB_FAIL_FLAG": fail_flag, "UNIT": "images/s"}
    json_info = json.dumps(info)
    with open(res_log_file, "w") as of:
        of.write(json_info)

if __name__ == "__main__":
    if len(sys.argv) != 5:
        print("Usage:" + sys.argv[0] + " model_name path/to/log/file path/to/res/log/file")
        sys.exit()

    model_name = sys.argv[1]
    batch_size = sys.argv[2]
    log_file = sys.argv[3]
    res_log_file = sys.argv[4]

    analyze(model_name, batch_size, log_file, res_log_file) 
