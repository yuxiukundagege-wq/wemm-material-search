# -*- coding: utf-8 -*-
"""索引目录初始化 / 校验（幂等）

后端服务启动时会直接读取索引目录下的 index256.npy / keys.json / assets.jsonl，
缺失会启动失败。本脚本负责把索引目录建成"可被后端直接读取"的最小合法状态
（0 条向量），用户随后在程序里"导入文件"即可增量建立索引。

用法:
    python init_index.py --run D:\\WeMM-Embedding\\temp\\index_run
    python init_index.py --run <索引目录> --check     # 只校验，不创建

返回码: 0=已就绪  2=需要创建但处于检查模式  3=索引存在但损坏(未做任何改动)
"""
import argparse
import json
import os
import sys

try:
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
except Exception:
    pass


def check(run_dir):
    """返回 (状态, 说明) 状态: ok / empty / broken"""
    idx256 = os.path.join(run_dir, 'index256.npy')
    keys = os.path.join(run_dir, 'keys.json')
    assets = os.path.join(run_dir, 'assets.jsonl')
    if not os.path.exists(idx256) or not os.path.exists(keys):
        return 'empty', 'index256.npy / keys.json 不存在'
    try:
        import numpy as np
        m = np.load(idx256)
        k = json.load(open(keys, encoding='utf-8'))
    except Exception as ex:
        return 'broken', '索引文件无法解析: %r' % ex
    if m.ndim != 2 or m.shape[1] != 256:
        return 'broken', 'index256.npy 形状异常: %s' % (m.shape,)
    if len(k) != m.shape[0]:
        return 'broken', 'keys.json 条数(%d) 与向量行数(%d) 不一致' % (len(k), m.shape[0])
    if not os.path.exists(assets):
        return 'broken', 'assets.jsonl 缺失（无法把向量映射回素材文件）'
    return 'ok', '向量数 %d, 维度 %d' % (m.shape[0], m.shape[1])


def create(run_dir):
    import numpy as np
    for d in (run_dir, os.path.join(run_dir, 'frames'), os.path.join(run_dir, 'rsz'), os.path.join(run_dir, 'embs')):
        os.makedirs(d, exist_ok=True)
    np.save(os.path.join(run_dir, 'index256.npy'), np.zeros((0, 256), dtype=np.float32))
    np.save(os.path.join(run_dir, 'index2560.npy'), np.zeros((0, 2560), dtype=np.float32))
    with open(os.path.join(run_dir, 'keys.json'), 'w', encoding='utf-8') as f:
        json.dump([], f)
    for name in ('assets.jsonl', 'index_meta.jsonl'):
        open(os.path.join(run_dir, name), 'w', encoding='utf-8').close()
    with open(os.path.join(run_dir, 'index_summary.json'), 'w', encoding='utf-8') as f:
        json.dump({'vector_count': 0, 'images_done': 0, 'images_total': 0,
                   'videos_done': 0, 'videos_total': 0, 'failed': []}, f, ensure_ascii=False, indent=2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--run', required=True, help='索引目录（后端 --run 参数指向的目录）')
    ap.add_argument('--check', action='store_true')
    a = ap.parse_args()
    run_dir = os.path.abspath(a.run)
    state, msg = check(run_dir)
    if state == 'ok':
        print('INDEX_ALREADY_OK %s (%s)' % (run_dir, msg))
        return 0
    if state == 'broken':
        print('INDEX_BROKEN %s -> %s' % (run_dir, msg))
        print('提示: 索引已损坏，为安全起见未做任何改动。可把该目录改名备份后重跑部署脚本重建。')
        return 3
    print('INDEX_MISSING %s -> %s' % (run_dir, msg))
    if a.check:
        return 2
    create(run_dir)
    state, msg = check(run_dir)
    if state != 'ok':
        print('FAIL 初始化后校验失败: %s' % msg)
        return 3
    print('INDEX_CREATED %s (%s)。首次打开程序后，把素材拖进窗口点"导入文件"即可建立索引。' % (run_dir, msg))
    return 0


if __name__ == '__main__':
    sys.exit(main())
