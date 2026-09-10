# -*- coding: utf-8 -*-
"""WeMM 素材检索 —— 离线批量建索引（可选高级步骤，不复制素材文件）

与程序内"导入文件"的区别: 本脚本直接对【已存在的素材目录】原位建索引，
不会把素材复制到素材库里，适合素材已经在硬盘上、不想再占一份空间的情况。

用法:
    python build_index_local.py --src D:\\我的素材 --run D:\\WeMM-Embedding\\temp\\index_run --model D:\\WeMM-Embedding\\models\\WeMM-Embedding-4B
    python build_index_local.py --src <素材目录> --run <索引目录> --model <模型目录> --limit 20   # 先试跑 20 个
    python build_index_local.py ... --stage scan|embed|index    # 分阶段执行（天然断点续跑）
    python build_index_local.py ... --append                    # 追加进已有索引，不清空

特性: 断点续跑（已算好的向量不重算）、视频抽 3 帧、超高分辨率图自动降采样、
      每 30 个素材回收一次显存。
返回码: 0=成功  1=失败
"""
import argparse
import json
import os
import sys
import time
import traceback

try:
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
except Exception:
    pass

IMG_EXT = {'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.tiff', '.heic', '.jfif'}
VID_EXT = {'.mp4', '.mov', '.mkv', '.avi', '.m4v', '.webm', '.flv', '.wmv', '.ts', '.mpg', '.mpeg', '.3gp'}
FRAMES_PER_VIDEO = 3
NFRAME_BATCH = 30
RESIZE_MAX = 2048
PIXEL_CAP = 2048 * 2048

CFG = {}


def log(msg):
    line = '%s %s' % (time.strftime('%H:%M:%S'), msg)
    print(line, flush=True)
    try:
        with open(os.path.join(CFG['run'], 'progress.log'), 'a', encoding='utf-8') as f:
            f.write(line + '\n')
    except Exception:
        pass


def paths():
    run = CFG['run']
    return {
        'run': run,
        'frames': os.path.join(run, 'frames'),
        'rsz': os.path.join(run, 'rsz'),
        'embs': os.path.join(run, 'embs'),
        'assets': os.path.join(run, 'assets.jsonl'),
    }


def ensure_dirs():
    for k in ('run', 'frames', 'rsz', 'embs'):
        os.makedirs(paths()[k], exist_ok=True)


def load_existing():
    """读取已有索引（--append 用），返回 (keys, M256, M2560, assets_lines)"""
    p = paths()
    keys, m256, m2560, lines = [], None, None, []
    try:
        import numpy as np
        if os.path.exists(os.path.join(p['run'], 'keys.json')):
            keys = json.load(open(os.path.join(p['run'], 'keys.json'), encoding='utf-8'))
            m256 = np.load(os.path.join(p['run'], 'index256.npy'))
            m2560 = np.load(os.path.join(p['run'], 'index2560.npy'))
        if os.path.exists(p['assets']):
            lines = [json.loads(l) for l in open(p['assets'], encoding='utf-8') if l.strip()]
    except Exception as ex:
        log('WARN 读取已有索引失败(将忽略): %r' % ex)
        return [], None, None, []
    return keys, m256, m2560, lines


def iter_files(src, recursive):
    if recursive:
        for root, _dirs, files in os.walk(src):
            for fn in files:
                yield os.path.join(root, fn)
    else:
        for fn in os.listdir(src):
            fp = os.path.join(src, fn)
            if os.path.isfile(fp):
                yield fp


def scan():
    ensure_dirs()
    p = paths()
    old_assets, seen, maxi, maxv = [], set(), -1, -1
    if CFG['append']:
        for it in load_existing()[3]:
            old_assets.append(it)
            seen.add(os.path.normcase(os.path.abspath(it['path'])))
            if it['key'].startswith('img_'):
                maxi = max(maxi, int(it['key'][4:]))
            elif it['key'].startswith('vid_'):
                maxv = max(maxv, int(it['key'][4:]))
    imgs, vids, skipped = [], [], 0
    for fp in sorted(iter_files(CFG['src'], CFG['recursive'])):
        ext = os.path.splitext(fp)[1].lower()
        if ext not in IMG_EXT and ext not in VID_EXT:
            continue
        if os.path.normcase(os.path.abspath(fp)) in seen:
            skipped += 1
            continue
        (imgs if ext in IMG_EXT else vids).append(fp)
    with open(p['assets'], 'w', encoding='utf-8') as f:
        for it in old_assets:
            f.write(json.dumps(it, ensure_ascii=False) + '\n')
        for i, fp in enumerate(imgs):
            f.write(json.dumps({'key': 'img_%05d' % (maxi + 1 + i), 'path': fp, 'type': 'image'}, ensure_ascii=False) + '\n')
        for j, fp in enumerate(vids):
            f.write(json.dumps({'key': 'vid_%05d' % (maxv + 1 + j), 'path': fp, 'type': 'video'}, ensure_ascii=False) + '\n')
    log('SCAN 目录=%s 新增图片=%d 新增视频=%d 已在索引内跳过=%d 素材清单=%d 条'
        % (CFG['src'], len(imgs), len(vids), skipped, len(old_assets) + len(imgs) + len(vids)))


def load_assets(limit=None, only_new=True):
    p = paths()
    items = [json.loads(l) for l in open(p['assets'], encoding='utf-8') if l.strip()]
    if only_new and CFG['append']:
        done_keys = set(load_existing()[0])
        frames_done = set(k[:-3] for k in done_keys if k.endswith(('_f0', '_f1', '_f2')))
        items = [it for it in items if it['key'] not in done_keys and it['key'] not in frames_done]
    if limit:
        items = items[:limit]
    return items


def get_video_frames(item):
    p = paths()
    key = item['key']
    outs = []
    for k in range(FRAMES_PER_VIDEO):
        fp = os.path.join(p['frames'], '%s_f%d.jpg' % (key, k))
        if os.path.exists(fp):
            outs.append(fp)
    if len(outs) == FRAMES_PER_VIDEO:
        return outs
    from decord import VideoReader, cpu
    from PIL import Image
    vr = VideoReader(item['path'], ctx=cpu(0))
    n = len(vr)
    idxs = sorted(set([0, n // 2, n - 1]))
    fr = []
    for k, idx in enumerate(idxs):
        arr = vr[idx].asnumpy()
        fp = os.path.join(p['frames'], '%s_f%d.jpg' % (key, k))
        Image.fromarray(arr).save(fp)
        fr.append(fp)
    return fr


def maybe_downscale(img_path):
    from PIL import Image
    p = paths()
    try:
        im = Image.open(img_path)
        w, h = im.size
        need = w > RESIZE_MAX or h > RESIZE_MAX or w * h > PIXEL_CAP
        mode_bad = im.mode != 'RGB'
        if not need and mode_bad:
            im = im.convert('RGB')
            out = os.path.join(p['rsz'], '_tmp_rgb.png')
            im.save(out)
            return out
        if not need:
            return img_path
        scale = float(RESIZE_MAX) / max(w, h)
        nw, nh = max(1, int(w * scale + 0.5)), max(1, int(h * scale + 0.5))
        if nw * nh > PIXEL_CAP:
            scale = (float(PIXEL_CAP) / (nw * nh)) ** 0.5
            nw, nh = max(1, int(nw * scale)), max(1, int(nh * scale))
        im = im.convert('RGB').resize((nw, nh), Image.LANCZOS)
        out = os.path.join(p['rsz'], os.path.splitext(os.path.basename(img_path))[0] + '_rsz.jpg')
        im.save(out, 'JPEG', quality=90)
        return out
    except Exception as ex:
        log('DOWNSCALE_SKIP %s err=%r' % (os.path.basename(img_path), ex))
        return img_path


def embed_one(model, processor, img_path):
    from qwen_vl_utils import process_vision_info
    import numpy as np
    import torch
    img_path = maybe_downscale(img_path)
    m = [{'role': 'user', 'content': [{'type': 'image', 'image': img_path}]}]
    prompt = processor.apply_chat_template(m, tokenize=False, add_generation_prompt=False)
    images, videos, video_kwargs = process_vision_info(m, image_patch_size=16, return_video_kwargs=True, return_video_metadata=True)
    inputs = processor(text=prompt, images=images, videos=videos, return_tensors='pt', max_pixels=12845056, **video_kwargs)
    inputs = {k: v.to('cuda') for k, v in inputs.items() if hasattr(v, 'to')}
    with torch.inference_mode():
        e = model.embedding(**inputs).float()[0].cpu().numpy()
    e = e / (np.linalg.norm(e) + 1e-9)
    return e


def run_embed(limit=None):
    import numpy as np
    import torch
    from transformers import AutoModel, AutoProcessor, BitsAndBytesConfig
    ensure_dirs()
    p = paths()
    items = load_assets(limit)
    log('EMBED 开始: 待处理素材 %d 个 (已算过的会自动跳过)' % len(items))
    if not items:
        log('EMBED 无新增素材，跳过')
        return
    t0 = time.time()
    bnb = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type='nf4', bnb_4bit_compute_dtype=torch.bfloat16)
    model = AutoModel.from_pretrained(CFG['model'], quantization_config=bnb, device_map={'': 0},
                                     torch_dtype=torch.bfloat16, trust_remote_code=True)
    processor = AutoProcessor.from_pretrained(CFG['model'], trust_remote_code=True)
    log('EMBED 模型加载完成 %.0fs' % (time.time() - t0))
    done = failed = skip = 0
    for idx, item in enumerate(items):
        if item['type'] == 'image':
            keys = [(item['key'], item['path'])]
        else:
            try:
                frames = get_video_frames(item)
            except Exception as ex:
                failed += 1
                log('FAIL %s 抽帧失败: %r' % (item['key'], ex))
                continue
            keys = [('%s_f%d' % (item['key'], k), fp) for k, fp in enumerate(frames)]
        for key, img_path in keys:
            npy = os.path.join(p['embs'], key + '.npy')
            if os.path.exists(npy):
                skip += 1
                continue
            try:
                np.save(npy, embed_one(model, processor, img_path))
                done += 1
            except Exception as ex:
                failed += 1
                log('FAIL %s 向量化失败: %r' % (key, ex))
        if (idx + 1) % 5 == 0:
            log('EMBED 进度 %d/%d 成功=%d 失败=%d 跳过=%d 用时=%.0fs'
                % (idx + 1, len(items), done, failed, skip, time.time() - t0))
        if (idx + 1) % NFRAME_BATCH == 0:
            import gc
            gc.collect(); torch.cuda.empty_cache()
    log('EMBED 结束 成功=%d 失败=%d 跳过=%d 用时=%.0fs' % (done, failed, skip, time.time() - t0))


def build_index():
    import numpy as np
    ensure_dirs()
    p = paths()
    old_keys, old256, old2560 = ([], None, None)
    if CFG['append']:
        old_keys, old256, old2560, _ = load_existing()
    old_set = set(str(k) for k in old_keys)
    embs, keys, meta_new = [], [], []
    for fn in sorted(os.listdir(p['embs'])):
        if not fn.endswith('.npy'):
            continue
        key = fn[:-4]
        if key in old_set:
            continue
        try:
            v = np.load(os.path.join(p['embs'], fn))
        except Exception:
            continue
        if v.shape[0] != 2560:
            log('SKIP %s 维度异常 %s' % (key, v.shape))
            continue
        embs.append(v)
        keys.append(key)
        base, frame = key, None
        for sfx in ('_f0', '_f1', '_f2'):
            if key.endswith(sfx):
                base, frame = key[:-3], key[-1:]
        meta_new.append({'key': key, 'base': base, 'frame': frame})

    def split(key):
        for sfx in ('_f0', '_f1', '_f2'):
            if key.endswith(sfx):
                return key[:-3], key[-1:]
        return key, None

    keys_all, l256, l2560, meta = [], [], [], []
    if old_keys and old256 is not None:
        keys_all += [str(k) for k in old_keys]
        l256.append(np.asarray(old256, dtype=np.float32))
        l2560.append(np.asarray(old2560 if old2560 is not None else old256, dtype=np.float32))
        for k in old_keys:
            b, fr = split(str(k))
            meta.append({'key': str(k), 'base': b, 'frame': fr})
    if keys:
        M = np.stack(embs).astype(np.float32)
        keys_all += keys
        l256.append(M[:, :256])
        l2560.append(M)
        meta += meta_new
    if not keys_all:
        log('INDEX 没有任何向量，无法建立索引（请先确认素材目录内有图片/视频，且 --stage embed 已执行）')
        return 1
    M256 = np.concatenate(l256, axis=0)
    M256 = M256 / (np.linalg.norm(M256, axis=1, keepdims=True) + 1e-9)
    M2560 = np.concatenate(l2560, axis=0)
    np.save(os.path.join(p['run'], 'index256.npy'), M256.astype(np.float32))
    np.save(os.path.join(p['run'], 'index2560.npy'), M2560.astype(np.float32))
    with open(os.path.join(p['run'], 'keys.json'), 'w', encoding='utf-8') as f:
        json.dump(keys_all, f, ensure_ascii=False)
    with open(os.path.join(p['run'], 'index_meta.jsonl'), 'w', encoding='utf-8') as f:
        for m in meta:
            f.write(json.dumps(m, ensure_ascii=False) + '\n')
    assets = [json.loads(l) for l in open(p['assets'], encoding='utf-8') if l.strip()]
    base_ok = set(m['base'] for m in meta)
    imgs = [a for a in assets if a['type'] == 'image' and a['key'] in base_ok]
    vids = [a for a in assets if a['type'] == 'video'
            and all('%s_f%d' % (a['key'], k) in base_ok for k in range(FRAMES_PER_VIDEO))]
    summary = {'vector_count': len(keys_all), 'images_done': len(imgs),
               'images_total': sum(1 for a in assets if a['type'] == 'image'),
               'videos_done': len(vids), 'videos_total': sum(1 for a in assets if a['type'] == 'video'),
               'failed': []}
    with open(os.path.join(p['run'], 'index_summary.json'), 'w', encoding='utf-8') as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)
    log('INDEX 完成: 向量 %d 条, 图片 %d/%d, 视频 %d/%d'
        % (summary['vector_count'], summary['images_done'], summary['images_total'],
           summary['videos_done'], summary['videos_total']))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', required=True, help='素材所在目录')
    ap.add_argument('--run', required=True, help='索引目录')
    ap.add_argument('--model', required=True, help='WeMM-Embedding-4B 模型目录')
    ap.add_argument('--stage', default='all', choices=['all', 'scan', 'embed', 'index'])
    ap.add_argument('--limit', type=int, default=None, help='只处理前 N 个素材（试跑用）')
    ap.add_argument('--append', action='store_true', help='追加到已有索引，而不是重建')
    ap.add_argument('--recursive', action='store_true', help='递归子目录')
    a = ap.parse_args()
    CFG.update(vars(a))
    CFG['src'] = os.path.abspath(a.src)
    CFG['run'] = os.path.abspath(a.run)
    CFG['model'] = os.path.abspath(a.model)
    if not os.path.isdir(CFG['src']):
        print('FAIL 素材目录不存在: %s' % CFG['src'])
        return 1
    if not os.path.isdir(CFG['model']):
        print('FAIL 模型目录不存在: %s' % CFG['model'])
        return 1
    try:
        if a.stage in ('all', 'scan'):
            scan()
        if a.stage in ('all', 'embed'):
            if not os.path.exists(paths()['assets']):
                scan()
            run_embed(limit=a.limit)
        if a.stage in ('all', 'index'):
            return build_index()
        return 0
    except Exception:
        print('FAIL 异常终止:\n' + traceback.format_exc())
        return 1


if __name__ == '__main__':
    sys.exit(main())
