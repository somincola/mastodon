#!/usr/bin/env python3
"""Select a stable patch release and keep publication separate from deployment."""
import json
import os
from pathlib import Path
import re
import subprocess


def version(value):
    if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', value):
        raise ValueError(f'Not a stable version: {value!r}')
    return tuple(map(int, value[1:].split('.')))


def plan(current, published, tags, requested='', force=False, reuse=False,
         publish=True, deploy=True, main=True):
    current_number, published_number = version(current), version(published)
    stable = [tag for tag in tags if re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag)]
    candidates = [tag for tag in stable if version(tag)[:2] == current_number[:2]]
    target = requested or max(candidates, key=version)
    target_number = version(target)
    if target not in stable:
        raise ValueError(f'Upstream tag does not exist: {target}')
    publish = publish and main
    deploy = deploy and main
    if deploy and not publish:
        raise ValueError('Deployment requires publish_latest=true; use skip_deploy for version-only builds.')
    if publish and target_number < max(current_number, published_number):
        raise ValueError('Refusing to move latest or production backwards; use version-only build options.')
    if publish and target_number[:2] != current_number[:2]:
        raise ValueError('Cross-minor upgrades require a separate migration review; use version-only build options.')
    run = force or bool(requested) or target != published or (deploy and target != current)
    return {
        'version': target,
        'version_clean': target[1:],
        'should_run': run,
        'build_images': run and not reuse and (force or target != published or not publish),
        'publish_latest': publish and run,
        'deploy': deploy and run,
    }


if __name__ == '__main__':
    tags = subprocess.check_output(['git', 'tag', '-l'], text=True).splitlines()
    result = plan(
        Path('.current-version').read_text().strip(),
        Path('.published-version').read_text().strip(),
        tags,
        requested=os.getenv('REQUESTED_VERSION', ''),
        force=os.getenv('FORCE_BUILD') == 'true',
        reuse=os.getenv('REUSE_IMAGES') == 'true',
        publish=os.getenv('PUBLISH_LATEST') != 'false',
        deploy=os.getenv('SKIP_DEPLOY') != 'true',
        main=os.getenv('GITHUB_REF') == 'refs/heads/main',
    )
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        for key, value in result.items():
            output.write(f'{key}={str(value).lower() if isinstance(value, bool) else value}\n')
    print(json.dumps(result))
