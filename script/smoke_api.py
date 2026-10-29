#!/usr/bin/env python3
"""Exercise real local inference without printing the API key or vector contents."""
import argparse
import json
from pathlib import Path
import time
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', default='http://127.0.0.1:18767')
    parser.add_argument('--key-file', type=Path, required=True)
    parser.add_argument('--generation-model', default='qwen3.5:4b')
    parser.add_argument('--decision-model', default='clef-flash:9b-mxfp8')
    parser.add_argument('--embedding-model', default='embeddinggemma:latest')
    args = parser.parse_args()
    key = args.key_file.expanduser().read_text().strip()
    receipts = []

    def call(path, body=None, authenticated=True):
        headers = {'Content-Type': 'application/json'}
        if authenticated:
            headers['Authorization'] = 'Bearer ' + key
        request = urllib.request.Request(args.url.rstrip('/') + path,
                                         data=None if body is None else json.dumps(body).encode(), headers=headers)
        started = time.monotonic()
        with urllib.request.urlopen(request, timeout=125) as response:
            result = json.load(response)
        return result, round((time.monotonic() - started) * 1000)

    try:
        call('/v1/models', authenticated=False)
        raise AssertionError('Unauthenticated request was accepted')
    except urllib.error.HTTPError as error:
        assert error.code == 401
    models, _ = call('/v1/models')
    available = {model['id'] for model in models if model['available']}
    assert {'apple', args.generation_model, args.decision_model, args.embedding_model} <= available
    schema = {'type': 'object', 'properties': {'text': {'type': 'string'}}, 'required': ['text']}
    for model in ['apple', args.generation_model]:
        result, elapsed = call('/v1/generate', {'model': model, 'prompt': 'Write one short greeting.',
                                               'schema': schema, 'maxTokens': 128})
        assert result['model'] == model and result['content']['text'].strip()
        receipts.append({'capability': 'structured generation', 'model': model, 'elapsedMS': elapsed})
        print(json.dumps(receipts[-1]), flush=True)
    result, elapsed = call('/v1/decisions', {'model': args.decision_model,
        'state': 'The checkout returns HTTP 500 errors for every purchase.',
        'questions': {'team': {'type': 'choice', 'instructions': 'Which team should handle this?',
                              'criteria': {'billing': 'Invoices and refunds without software failure',
                                           'technical': 'Software failures and outages'}}}})
    assert result['model'] == args.decision_model
    assert result['answers']['team']['choice'] == 'technical'
    assert result['usage']['input_tokens'] > 0
    receipts.append({'capability': 'decision', 'model': args.decision_model, 'elapsedMS': elapsed,
                     'choice': result['answers']['team']['choice']})
    print(json.dumps(receipts[-1]), flush=True)
    result, elapsed = call('/v1/embeddings', {'model': args.embedding_model, 'input': ['Walking by the river.', 'A riverside walk.']})
    assert result['model'] == args.embedding_model and len(result['embeddings']) == 2
    dimensions = len(result['embeddings'][0])
    assert dimensions > 0 and all(len(vector) == dimensions for vector in result['embeddings'])
    assert result['usage']['input_tokens'] > 0
    receipts.append({'capability': 'embedding', 'model': args.embedding_model, 'elapsedMS': elapsed, 'dimensions': dimensions})
    print(json.dumps(receipts[-1]), flush=True)
    print(json.dumps({'passed': True, 'authenticated': True, 'inferenceChecks': len(receipts)}), flush=True)


if __name__ == '__main__':
    main()
