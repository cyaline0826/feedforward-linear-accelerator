"""Export KWT-1 float references, convert parameters/inputs, and evaluate decoded outputs."""
import argparse
import hashlib
import json
import platform
import random
import subprocess
import sys
from pathlib import Path

import numpy as np
from 软件数值模型 import FORMAT, encode, decode, fc1, read_tensor, write_tensor

SEED = 59185


def check_fc1(x, weight, bias, output):
    for name, array, shape in (
        ("input", x, (99, 64)),
        ("weight", weight, (64, 256)),
        ("bias", bias, (256,)),
        ("output", output, (99, 256)),
    ):
        if array.shape != shape or array.dtype != np.float32:
            raise ValueError("{} must be float32 with shape {}".format(name, shape))
        if not np.isfinite(array).all():
            raise ValueError("{} contains NaN or infinity".format(name))
    # Independent float64 arithmetic detects wrong axes, bias or activation taps.
    reference = x.astype(np.float64) @ weight.astype(np.float64) + bias
    error = output.astype(np.float64) - reference
    nrmse = float(np.sqrt(np.mean(error ** 2)) /
                  max(float(np.sqrt(np.mean(reference ** 2))), 1e-8))
    if nrmse > 1e-5:
        raise ValueError("FC1 does not match X @ W + b: NRMSE={:.6g}".format(nrmse))
    return {"nrmse": nrmse, "max_abs_error": float(np.max(np.abs(error)))}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def export_reference(args, parser):
    if args.count <= 0:
        parser.error("--count must be positive")

    repo = Path.cwd()
    model_dir = repo / "models_data_v2_12_labels" / "kwt1"
    data_dir = args.data_dir.resolve()
    if not (repo / "kws_streaming").is_dir():
        parser.error("Run from the keyword-transformer repository root")
    commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=str(repo), text=True).strip()
    if not commit.startswith("237e4097"):
        parser.error("The checkout must be at commit 237e4097")
    clean = subprocess.run(
        ["git", "diff", "--quiet", "HEAD", "--", "kws_streaming",
         "models_data_v2_12_labels/kwt1"], cwd=str(repo))
    if clean.returncode != 0:
        parser.error("Model source/weights/config differ from the specified commit")
    if args.out.exists():
        parser.error("Output already exists; choose a new --out directory")
    for path in (data_dir / "yes", data_dir / "no", data_dir / "_background_noise_"):
        if not path.is_dir():
            parser.error("Dataset directory is missing: {}".format(path))
    for path in (model_dir / "flags.json", model_dir / "labels.txt",
                 model_dir / "best_weights.index"):
        if not path.is_file():
            parser.error("Model file is missing: {}".format(path))

    sys.path.insert(0, str(repo))
    import tensorflow as tensorflow
    import tensorflow.compat.v1 as tf
    import tensorflow_addons as tfa
    from kws_streaming.data import input_data
    from kws_streaming.models import models  # Initialize registry before KWT's utils import.
    from kws_streaming.models import kws_transformer, model_flags
    from kws_streaming.models.transformer_utils import KWSTransformer
    from kws_streaming.train import base_parser

    if tensorflow.__version__ not in ("2.4.0rc1", "2.4.0"):
        parser.error("Use TensorFlow 2.4.0rc1 or the documented 2.4.0 alternative")

    defaults = base_parser.base_parser()
    kws_transformer.model_parameters(defaults)
    flags = defaults.parse_args([])
    vars(flags).update(json.loads((model_dir / "flags.json").read_text()))
    expected = {"model_name": "kws_transformer", "num_layers": 12,
                "d_model": 64, "mlp_dim": 256, "heads": 1,
                "attention_type": "time", "prenorm": False,
                "preprocess": "raw", "feature_type": "mfcc_tf"}
    for name, value in expected.items():
        if getattr(flags, name) != value:
            raise ValueError("Unexpected KWT-1 setting: {}".format(name))
    if flags.distill_teacher_json or flags.approximate_gelu:
        raise ValueError("This exporter requires the non-distilled, exact-GELU model")
    vars(flags).update(
        data_url="", data_dir=str(data_dir), train_dir=str(model_dir),
        train=0, training=False, batch_size=1, pick_deterministically=1,
        use_spec_augment=0, use_spec_cutout=0,
        time_shift_ms=0.0, sp_time_shift_ms=0.0,
        resample=0.0, sp_resample=0.0, volume_resample=0.0,
        background_frequency=0.0, background_volume=0.0,
    )
    flags = model_flags.update_flags(flags)
    labels = (model_dir / "labels.txt").read_text().splitlines()

    tf.reset_default_graph()
    random.seed(SEED)
    np.random.seed(SEED)
    tf.set_random_seed(SEED)
    config = tf.ConfigProto(device_count={"GPU": 0},
                            intra_op_parallelism_threads=1,
                            inter_op_parallelism_threads=1)
    with tf.Session(config=config) as session:
        tf.keras.backend.set_session(session)
        tf.keras.backend.set_learning_phase(0)
        processor = input_data.AudioProcessor(flags)
        if processor.words_list != labels:
            raise ValueError("Dataset label order differs from the weight directory")
        candidates = processor.data_index[args.split]
        if args.count > len(candidates):
            raise ValueError("Requested {} samples, but {} contains {}".format(
                args.count, args.split, len(candidates)))

        model = kws_transformer.model(flags)
        transformer = next(layer for layer in model.layers
                           if isinstance(layer, KWSTransformer))
        tokens = transformer.patch_proj(transformer.input)
        class_token = tf.broadcast_to(transformer.class_emb, [1, 1, 64])
        tokens = tf.concat([class_token, tokens], axis=1) + transformer.pos_emb
        fetches = {"audio": model.input, "mfcc": transformer.input,
                   "encoder_input": tokens, "logits": model.outputs[0]}
        parameters = []
        if len(transformer.enc_layers) != 12:
            raise ValueError("Expected 12 encoder layers")
        for index, block in enumerate(transformer.enc_layers):
            attention, _ = block.att(tokens)
            x = block.layernorm1(tokens + block.dropout1(attention, training=False))
            dense = block.ffn.layers[0]
            fetches["layer_{:02d}_x".format(index)] = x
            fetches["layer_{:02d}_y".format(index)] = dense(x)
            parameters.append((dense.kernel, dense.bias))
            # shortcut: extra attention ops expose FC1; optimize only if export is slow.
            tokens, _ = block(tokens, training=False)
        fetches["class_reference"] = transformer.output
        fetches["class_tapped"] = tokens[:, 0]

        session.run(tf.global_variables_initializer())
        status = model.load_weights(str(model_dir / "best_weights"))
        status.assert_existing_objects_matched()
        status.expect_partial()  # Checkpoint optimizer slots need not be restored.
        parameters = session.run(parameters)

        args.out.mkdir(parents=True, exist_ok=False)
        (args.out / "params").mkdir()
        metadata = {
            "complete": False, "commit": commit, "split": args.split,
            "count": args.count, "seed": SEED,
            "python": sys.version, "platform": platform.platform(),
            "tensorflow": tensorflow.__version__, "tensorflow_addons": tfa.__version__,
            "numpy": np.__version__, "labels": labels, "flags": vars(flags),
            "uses_original_tensorflow_version": tensorflow.__version__ == "2.4.0rc1",
            "format": "NPZ float32, row-major; layer indices 00..11; Y = X @ W + b before GELU",
            "source_sha256": {
                str(path.relative_to(repo)): sha256(path)
                for path in [model_dir / "flags.json", model_dir / "labels.txt"]
                + sorted(model_dir.glob("best_weights.*"))
            },
            "export_script_sha256": sha256(Path(__file__)),
            "parameters": [], "samples": [],
        }
        manifest = args.out / "manifest.json"
        manifest.write_text(json.dumps(metadata, indent=2, allow_nan=False), encoding="utf-8")
        for index, (weight, bias) in enumerate(parameters):
            filename = "params/layer_{:02d}.npz".format(index)
            np.savez(str(args.out / filename), weight=weight, bias=bias)
            metadata["parameters"].append({"file": filename,
                                            "sha256": sha256(args.out / filename)})

        correct = 0
        for index, sample in enumerate(candidates[:args.count]):
            audio, target = processor.get_data(
                1, index, flags, 0.0, 0.0, 0, args.split, 0.0, 0.0, session)
            audio = audio.astype(np.float32)
            label = int(target[0])
            if sample["label"] == input_data.SILENCE_LABEL and np.any(audio):
                raise ValueError("Silence input must be the all-zero waveform")
            result = session.run(fetches, feed_dict={model.input: audio})
            np.testing.assert_allclose(result.pop("class_tapped"),
                                       result.pop("class_reference"), rtol=1e-5, atol=1e-5)
            result = {name: array[0] for name, array in result.items()}
            if result["mfcc"].shape != (98, 40) or result["encoder_input"].shape != (99, 64):
                raise ValueError("Unexpected MFCC or encoder-input shape")
            if not all(np.isfinite(array).all() for array in result.values()):
                raise ValueError("Model produced NaN or infinity")
            errors = []
            for layer, (weight, bias) in enumerate(parameters):
                errors.append(check_fc1(result["layer_{:02d}_x".format(layer)],
                                        weight, bias, result["layer_{:02d}_y".format(layer)]))
            filename = "sample_{:06d}.npz".format(index)
            np.savez(str(args.out / filename), **result)
            silence = sample["label"] == input_data.SILENCE_LABEL
            source = Path(sample["file"])
            prediction = int(np.argmax(result["logits"]))
            correct += prediction == label
            metadata["samples"].append({
                "file": filename, "sha256": sha256(args.out / filename),
                "partition_index": index, "original_word": sample["label"],
                "label_id": label, "prediction_id": prediction,
                "source_wav": None if silence else str(source.relative_to(data_dir)),
                "source_wav_sha256": None if silence else sha256(source),
                "silence_is_all_zero": silence, "fc1_checks": errors,
            })
            print("[{}/{}] {}: 12 layers checked".format(index + 1, args.count, filename),
                  flush=True)

        freeze = subprocess.check_output([sys.executable, "-m", "pip", "freeze"], text=True)
        (args.out / "environment.freeze.txt").write_text(freeze, encoding="utf-8")
        metadata.update(complete=True, subset_accuracy=correct / args.count)
        manifest.write_text(json.dumps(metadata, indent=2, allow_nan=False), encoding="utf-8")
        print("DONE: {} (subset accuracy {:.2%}; not a full benchmark)".format(
            args.out.resolve(), metadata["subset_accuracy"]))


def load_manifest(root):
    root = Path(root)
    manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8'))
    if manifest.get('complete') is not True:
        raise ValueError('Incomplete export')
    entries = manifest['samples']
    if not entries or len(entries) != manifest['count']:
        raise ValueError('Sample count mismatch')
    for entry in manifest['parameters'] + entries:
        path = (root / entry['file']).resolve()
        if root.resolve() not in path.parents or sha256(path) != entry['sha256']:
            raise ValueError('Unsafe path or hash mismatch: ' + str(path))
    return manifest


def save_manifest(out, manifest):
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2, allow_nan=False),
                                       encoding='utf-8')


def convert(reference, out):
    manifest = load_manifest(reference)
    if not manifest['commit'].startswith('237e4097'):
        raise ValueError('Wrong upstream revision')
    if manifest['split'] not in ('training', 'validation'):
        raise ValueError('Do not use test data for numeric development')
    if [p['file'] for p in manifest['parameters']] != [
            'params/layer_{:02d}.npz'.format(i) for i in range(12)]:
        raise ValueError('Expected all 12 FC1 parameter sets')
    out.mkdir(parents=True, exist_ok=False)
    result = {'format': FORMAT, 'complete': False, 'count': manifest['count'],
              'split': manifest['split'], 'commit': manifest['commit'],
              'reference_manifest_sha256': sha256(reference / 'manifest.json'),
              'parameters': [], 'samples': [], 'quantization_clips': {}}
    save_manifest(out, result)

    def store(relative, value, kind):
        q, clips = encode(value, kind)
        result['quantization_clips'][kind] = result['quantization_clips'].get(kind, 0) + clips
        write_tensor(out / relative, q, kind)
        return [{'file': str(Path(relative).with_suffix(ext)).replace('\\', '/'),
                 'sha256': sha256((out / relative).with_suffix(ext))} for ext in ('.bin', '.hex')]

    for layer, entry in enumerate(manifest['parameters']):
        with np.load(reference / entry['file'], allow_pickle=False) as data:
            for kind in ('weight', 'bias'):
                result['parameters'] += store('params/layer_{:02d}_{}.bin'.format(layer, kind),
                                               data[kind], kind)
    for index, entry in enumerate(manifest['samples']):
        files = []
        with np.load(reference / entry['file'], allow_pickle=False) as data:
            for layer in range(12):
                files += store('sample_{:06d}/layer_{:02d}_x.bin'.format(index, layer),
                               data['layer_{:02d}_x'.format(layer)], 'x')
        result['samples'].append({'index': index, 'reference_file': entry['file'], 'files': files})
    result['complete'] = True
    save_manifest(out, result)
    print('CONVERTED', result['count'], 'samples; clips:', result['quantization_clips'])


def convert_fc2(reference, out):
    manifest = json.loads((reference / 'manifest.json').read_text(encoding='utf-8'))
    if (manifest.get('complete') is not True
            or manifest.get('commit') != '237e4097afd4f6851e0b82f0a8d65c2dfe8eae30'
            or [entry['file'] for entry in manifest['parameters']] != [
                'layer_{:02d}.npz'.format(i) for i in range(12)]):
        raise ValueError('Expected complete original FC2 parameters for all 12 layers')
    tensors = []
    clips = {'weight2': 0, 'bias2': 0}
    for layer, entry in enumerate(manifest['parameters']):
        path = (reference / entry['file']).resolve()
        if reference.resolve() not in path.parents or sha256(path) != entry['sha256']:
            raise ValueError('FC2 parameter path/hash mismatch: ' + str(path))
        with np.load(path, allow_pickle=False) as data:
            for source_kind, kind in (('weight', 'weight2'), ('bias', 'bias2')):
                values, count = encode(data[source_kind], kind)
                clips[kind] += count
                tensors.append((layer, kind, values))
    out.mkdir(parents=True, exist_ok=False)
    result = {'format': FORMAT + '_fc2', 'complete': False, 'layers': 12,
              'reference_manifest_sha256': sha256(reference / 'manifest.json'),
              'quantization_clips': clips, 'parameters': []}
    save_manifest(out, result)
    for layer, kind, values in tensors:
        path = out / 'layer_{:02d}_{}.bin'.format(layer, kind)
        write_tensor(path, values, kind)
        for suffix in ('.bin', '.hex'):
            file = path.with_suffix(suffix)
            result['parameters'].append({'file': file.name, 'sha256': sha256(file)})
    result['complete'] = True
    save_manifest(out, result)
    print('CONVERTED 12 FC2 layers; clips:', clips)


def load_encoded(root):
    manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8'))
    if manifest.get('format') != FORMAT or manifest.get('complete') is not True:
        raise ValueError('Wrong format or incomplete conversion')
    if not manifest['samples'] or len(manifest['samples']) != manifest['count']:
        raise ValueError('Sample count mismatch')
    entries = manifest['parameters'] + [f for s in manifest['samples'] for f in s['files']]
    for entry in entries:
        path = (root / entry['file']).resolve()
        if root.resolve() not in path.parents or sha256(path) != entry['sha256']:
            raise ValueError('Encoded data hash/path mismatch: ' + str(path))
    return manifest


def run(encoded, out):
    manifest = load_encoded(encoded)
    out.mkdir(parents=True, exist_ok=False)
    counts = {'accumulator_overflow': 0, 'output_saturation': 0}
    for sample in manifest['samples']:
        for layer in range(12):
            base = 'sample_{:06d}/layer_{:02d}'.format(sample['index'], layer)
            y, stats = fc1(read_tensor(encoded / (base + '_x.bin'), 'x'),
                           read_tensor(encoded / 'params' / ('layer_{:02d}_weight.bin'.format(layer)), 'weight'),
                           read_tensor(encoded / 'params' / ('layer_{:02d}_bias.bin'.format(layer)), 'bias'))
            write_tensor(out / (base + '_y.bin'), y, 'y')
            for key in counts:
                counts[key] += stats[key]
    (out / 'model_run.json').write_text(json.dumps({'format': FORMAT, 'count': manifest['count'],
                                                  'complete': True, **counts}, indent=2), encoding='utf-8')
    print('MODEL COMPLETE', counts)


def decode_outputs(reference, outputs, out):
    manifest = load_manifest(reference)
    out.mkdir(parents=True, exist_ok=False)
    result = {'format': FORMAT + '_decoded_float32', 'complete': False,
              'count': manifest['count'], 'split': manifest['split'],
              'source_reference_manifest_sha256': sha256(reference / 'manifest.json'),
              'parameters': [], 'samples': []}
    save_manifest(out, result)
    for index, entry in enumerate(manifest['samples']):
        arrays = {}
        for layer in range(12):
            relative = 'sample_{:06d}/layer_{:02d}_y.bin'.format(index, layer)
            # Every s12 Q8 value is exactly representable in float32.
            arrays['layer_{:02d}_y'.format(layer)] = decode(
                read_tensor(outputs / relative, 'y'), 'y').astype(np.float32)
        filename = 'sample_{:06d}.npz'.format(index)
        np.savez_compressed(str(out / filename), **arrays)
        result['samples'].append({'file': filename, 'sha256': sha256(out / filename),
                                  'source_sample_file': entry['file']})
        if (index + 1) % 64 == 0:
            print('DECODED {}/{}'.format(index + 1, manifest['count']), flush=True)
    result['complete'] = True
    save_manifest(out, result)
    print('DECODE COMPLETE:', result['count'], 'samples', flush=True)


def evaluate(reference, outputs=None, bit_exact=None, decoded=None, report_dir=None):
    manifest = load_manifest(reference)
    if manifest['split'] != 'validation':
        raise ValueError('Accuracy evaluation requires validation split')
    if (outputs is None) == (decoded is None):
        raise ValueError('Choose either encoded outputs or decoded results')
    if decoded is not None:
        if bit_exact is not None:
            raise ValueError('Use encoded --outputs for integer bit-exact comparison')
        decoded_manifest = load_manifest(decoded)
        if (decoded_manifest.get('format') != FORMAT + '_decoded_float32'
                or decoded_manifest.get('source_reference_manifest_sha256') != sha256(reference / 'manifest.json')
                or decoded_manifest['count'] != manifest['count']
                or [s.get('source_sample_file') for s in decoded_manifest['samples']]
                   != [s['file'] for s in manifest['samples']]):
            raise ValueError('Decoded results do not match this reference export')
    error, energy, elements = np.zeros(12), np.zeros(12), np.zeros(12, dtype=np.int64)
    mismatches = 0
    for index, entry in enumerate(manifest['samples']):
        decoded_values = {}
        if decoded is not None:
            with np.load(decoded / decoded_manifest['samples'][index]['file'], allow_pickle=False) as arrays:
                decoded_values = {name: arrays[name] for name in arrays.files}
        with np.load(reference / entry['file'], allow_pickle=False) as data:
            for layer in range(12):
                relative = 'sample_{:06d}/layer_{:02d}_y.bin'.format(index, layer)
                if decoded is None:
                    q = read_tensor(outputs / relative, 'y')
                    actual = decode(q, 'y')
                else:
                    actual = np.asarray(decoded_values['layer_{:02d}_y'.format(layer)], dtype=np.float64)
                target = np.asarray(data['layer_{:02d}_y'.format(layer)], dtype=np.float64)
                if (target.shape != (99, 256) or actual.shape != target.shape
                        or not np.isfinite(target).all() or not np.isfinite(actual).all()):
                    raise ValueError('Invalid reference or decoded output')
                error[layer] += np.sum((actual - target) ** 2)
                energy[layer] += np.sum(target ** 2)
                elements[layer] += target.size
                if bit_exact is not None:
                    mismatches += int(np.count_nonzero(q != read_tensor(bit_exact / relative, 'y')))
        if (index + 1) % 64 == 0:
            print('EVALUATED {}/{}'.format(index + 1, manifest['count']), flush=True)
    nrmse = np.sqrt(error / elements) / np.maximum(np.sqrt(energy / elements), 1e-8)
    passed = bool(np.isfinite(nrmse).all() and np.max(nrmse) <= .03 and mismatches == 0)
    report = {'count': manifest['count'], 'layer_nrmse': nrmse.tolist(),
              'max_layer_nrmse': float(np.max(nrmse)), 'bit_exact_checked': bit_exact is not None,
              'mismatched_elements': mismatches, 'accuracy_pass': passed}
    for layer, value in enumerate(nrmse):
        print('layer {:02d} NRMSE={:.6%}'.format(layer, value))
    print(json.dumps(report, indent=2))
    if report_dir is None:
        report_path = (outputs if outputs is not None else decoded) / 'evaluation.json'
    else:
        report_dir.mkdir(parents=True, exist_ok=True)
        report_path = report_dir / '比较结果.json'
    report_path.write_text(json.dumps(report, indent=2, allow_nan=False), encoding='utf-8')
    if not passed:
        raise SystemExit(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    export_parser = commands.add_parser('export', help='Generate float references from the official model')
    export_parser.add_argument('--data-dir', type=Path, default=Path('data2'))
    export_parser.add_argument('--split', choices=('training', 'validation'), required=True)
    export_parser.add_argument('--count', type=int, default=1)
    export_parser.add_argument('--out', type=Path, required=True)
    p = commands.add_parser('convert', help='Encode float weights, biases and inputs as bin/hex')
    p.add_argument('--reference', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p = commands.add_parser('convert-fc2', help='Encode original FC2 parameters as Q11 bin/hex')
    p.add_argument('--reference', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p = commands.add_parser('run', help='Run the submitted integer software model')
    p.add_argument('--encoded', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p = commands.add_parser('decode', help='Save encoded output tensors as decoded float32 NPZ files')
    p.add_argument('--reference', type=Path, required=True)
    p.add_argument('--outputs', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p = commands.add_parser('evaluate', help='Decode outputs and compare with float/model references')
    p.add_argument('--reference', type=Path, required=True)
    sources = p.add_mutually_exclusive_group(required=True)
    sources.add_argument('--outputs', type=Path)
    sources.add_argument('--decoded', type=Path)
    p.add_argument('--bit-exact', type=Path)
    p.add_argument('--report-dir', type=Path)
    args = parser.parse_args()
    if args.command == 'export':
        export_reference(args, export_parser)
    elif args.command == 'convert':
        convert(args.reference, args.out)
    elif args.command == 'convert-fc2':
        convert_fc2(args.reference, args.out)
    elif args.command == 'run':
        run(args.encoded, args.out)
    elif args.command == 'decode':
        decode_outputs(args.reference, args.outputs, args.out)
    else:
        evaluate(args.reference, args.outputs, args.bit_exact, args.decoded, args.report_dir)


if __name__ == '__main__':
    main()
