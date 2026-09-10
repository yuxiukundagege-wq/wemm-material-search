# -*- coding: utf-8 -*-
"""后端运行环境自检：检查依赖是否齐全、CUDA 是否可用。

供一键部署脚本调用，也方便用户手动排查:
    D:\\WeMM-Embedding\\venv\\Scripts\\python.exe tools\\check_env.py

输出:
    MISSING=none | MISSING=xxx(...)
    CUDA=OK | CUDA=NO
    GPU=<显卡名>  TORCH=<版本>
返回码: 0=完全可用  5=缺依赖或 CUDA 不可用
"""
import sys

MODS = ['torch', 'torchvision', 'transformers', 'numpy', 'decord', 'qwen_vl_utils',
        'bitsandbytes', 'PIL', 'psutil', 'accelerate', 'safetensors', 'huggingface_hub', 'av']

missing = []
for m in MODS:
    try:
        __import__(m)
    except Exception as e:
        missing.append('%s(%s)' % (m, type(e).__name__))

print('MISSING=%s' % (','.join(missing) if missing else 'none'))
cuda_ok = False
try:
    import torch
    print('TORCH=%s' % torch.__version__)
    cuda_ok = bool(torch.cuda.is_available())
    print('CUDA=%s' % ('OK' if cuda_ok else 'NO'))
    if cuda_ok:
        print('GPU=%s' % torch.cuda.get_device_name(0))
    else:
        print('HINT=PyTorch 检测不到 CUDA 设备(可能是 CPU 版 torch, 或显卡驱动异常)')
except Exception as e:
    print('CUDA=NO')
    print('HINT=导入 torch 失败: %r' % (e,))

sys.exit(0 if (not missing and cuda_ok) else 5)
