#!bin/bash

set -xe
if [[ $# -lt 4 ]]; then
    echo "running job dict is {1: speed, 3:profiler, 6:max_batch_size}"
    echo "Usage: "
    echo "  CUDA_VISIBLE_DEVICES=0 bash $0 1|3|6 32 model_name(ResNet50_bs32|ResNet50_bs128|ResNet101|SE_ResNeXt50_32x4d) sp|mp max_epoch"

    exit
fi

function _set_params(){
    index=$1                          # 速度(speed)|显存占用(mem)|单卡最大支持batch_size(maxbs)                       （必填）
    base_batch_size=$2                # 单卡的batch_size，如果固定的，可以写死。                                       (必填）
    model_name=$3                     # 模型名字如："SE-ResNeXt50"，如果是固定的，可以写死，如果需要其他参数可以参考bert实现（必填）
    run_mode=${4:-"sp"}               # 单进程(sp)|多进程(mp)，默认单进程                                             （必填）
    mission_name="图像分类"           # 模型所属任务名称，具体可参考scripts/config.ini                                （必填）
    direction_id=0                    # 任务所属方向，0：CV，1：NLP，2：Rec。                                          (必填)

    max_epoch=${5}
    if [[ ${index} -eq 3 ]]; then is_profiler=1; else is_profiler=0; fi

    run_log_path=${TRAIN_LOG_DIR:-$(pwd)}
    profiler_path=${PROFILER_LOG_DIR:-$(pwd)}

    skip_steps=8                      # 解析日志，有些模型前几个step耗时长，需要跳过                                  (必填)
    keyword="ips:"              # 解析日志，筛选出数据所在行的关键字                                            (必填)
    keyword_loss="loss:"       #选填
    model_mode=-1                      # 解析日志，具体参考scripts/analysis.py.                                        (必填)
    ips_unit="images/s" 

    devices=(${CUDA_VISIBLE_DEVICES//,/ })
    num_gpu_devices=${#devices[*]}

    log_file=${run_log_path}/${model_name}_${index}_${num_gpu_devices}_${run_mode}
    log_with_profiler=${profiler_path}/${model_name}_3_${num_gpu_devices}_${run_mode}
    profiler_path=${profiler_path}/profiler_${model_name}
    if [[ ${is_profiler} -eq 1 ]]; then log_file=${log_with_profiler}; fi
    log_parse_file=${log_file}

     if [ ${run_mode} == "sp" ]; then
        is_distributed=False
     else
        is_distributed=True
     fi
}

function _set_env(){
    #开启gc
    export FLAGS_eager_delete_tensor_gb=0.0
    export FLAGS_fraction_of_gpu_memory_to_use=0.98
    ####
    export FLAGS_cudnn_exhaustive_search=1
    export FLAGS_conv_workspace_size_limit=4000 #MB
}

function _train(){
    echo "current CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES, gpus=$num_gpu_devices, batch_size=$batch_size"
    WORK_ROOT=$PWD
    echo "${model_name}, batch_size: ${batch_size}"
    if [ ${model_name%%_bs*} == "ResNet50" ]; then
        config_file="ppcls/configs/ImageNet/ResNet/ResNet50.yaml"
    elif [ ${model_name%%_bs*} == "ResNet101" ]; then
         config_file="ppcls/configs/ImageNet/ResNet/ResNet101.yaml"
    elif [ ${model_name%%_bs*} == "SE_ResNeXt50_32x4d" ]; then
          config_file="ppcls/configs/ImageNet/SENet/SE_ResNeXt50_32x4d.yaml"
    else
        echo "model: $model_name not support!"
        exit
    fi

    # Enable the optimization options for ResNet50
    if [ ${model_name%%_bs*} == "ResNet50" ]; then
        fuse_elewise_add_act_ops="True"
        enable_addto="True"
        export FLAGS_max_inplace_grad_add=8
    else
        fuse_elewise_add_act_ops="False"
        enable_addto="False"
    fi

    train_cmd="-c $config_file
               -o Global.print_batch_step=10
               -o DataLoader.Train.sampler.batch_size=${base_batch_size}
               -o Global.eval_during_train=False
               -o DataLoader.Train.dataset.image_root=./dataset/imagenet100_data
               -o DataLoader.Train.dataset.cls_label_path=./dataset/imagenet100_data/train_list.txt
               -o fuse_elewise_add_act_ops=${fuse_elewise_add_act_ops}
               -o enable_addto=${enable_addto}
               -o DataLoader.Train.loader.num_workers=8
               -o Global.is_distributed=${is_distributed}
               -o Global.epochs=${max_epoch}"

    case ${run_mode} in
    sp) train_cmd="python -u ppcls/static/train.py "${train_cmd} ;;
    mp)
        rm -rf ./mylog_${model_name}
        if [ ${model_name} = "ResNet50_bs32" ] || [ ${model_name} = "ResNet50_bs128" ] || [ ${model_name} = "ResNet50_bs96" ]; then
            export FLAGS_fraction_of_gpu_memory_to_use=0.8
            train_cmd="python -m paddle.distributed.launch --log_dir=./mylog_${model_name} --gpus=$CUDA_VISIBLE_DEVICES ppcls/static/train.py "${train_cmd}" -o Global.use_dali=True"
        else
            train_cmd="python -m paddle.distributed.launch --log_dir=./mylog_${model_name} --gpus=$CUDA_VISIBLE_DEVICES ppcls/static/train.py "${train_cmd}
        fi
        log_parse_file="mylog_${model_name}/workerlog.0" ;;
    *) echo "choose run_mode(sp or mp)"; exit 1;
    esac

    timeout 5m ${train_cmd} > ${log_file} 2>&1
    if [ $? -ne 0 ];then
        echo -e "${model_name}, FAIL"
        export job_fail_flag=1
    else
        echo -e "${model_name}, SUCCESS"
        export job_fail_flag=0
    fi
    kill -9 `ps -ef|grep python |awk '{print $2}'`

    if [ $run_mode = "mp" -a -d mylog_${model_name} ]; then
        rm ${log_file}
        cp mylog_${model_name}/workerlog.0 ${log_file}
    fi
    cd ${WORK_ROOT}
}

source ${BENCHMARK_ROOT}/scripts/run_model.sh
_set_params $@
_set_env
_run
