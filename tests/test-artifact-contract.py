#!/usr/bin/env python3
"""Artifact contract tests using real ELF files; no Docker daemon or downloads."""
import hashlib
import io
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ArtifactContract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='mus-contract-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for directory in ('scripts', 'targets/audit', 'fixtures', 'dist/bin', 'dist/lib'):
            (self.root / directory).mkdir(parents=True)
        for name in ('verify-artifact.sh', 'system-runtime.sh'):
            shutil.copy2(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        (self.root / 'source.env').write_text('MPV_VERSION=0.41.0\n')
        (self.root / 'targets/audit/target.env').write_text('''TARGET_ID=audit
ARTIFACT_TARGET=audit
ARCH=x86_64
EXPECTED_MACHINE=x86_64
GLIBC_BASELINE=999.0
SOURCE_ENV=source.env
PORTABILITY_IMAGES=unused
DOCKER_PLATFORM=linux/amd64
''')
        for name in ('opus.webm', 'aac.m4a'):
            (self.root / 'fixtures' / name).write_bytes(b'fixture')
        self.dist = self.root / 'dist'
        self.source = self.root / 'main.c'
        self.source.write_text('''#include <stdio.h>
#include <string.h>

#ifdef NEED_ZLIB
extern const char *zlibVersion(void);
#endif
#ifdef NEED_AUDIT
extern int audit(void);
#endif

int main(int argc, char **argv) {
#ifdef NEED_ZLIB
    if (!zlibVersion()) return 1;
#endif
#ifdef NEED_AUDIT
    if (!audit()) return 1;
#endif
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--version")) {
            puts("mpv 0.41.0");
            return 0;
        }
        if (!strcmp(argv[i], "--ao=help")) {
            puts("pulse\\nalsa");
            return 0;
        }
    }
    fputs("TEST_RUNTIME_REACHED\\n", stderr);
    return 77;
}
''')
        self.compile()

    def compile(self, *flags):
        subprocess.run(
            ['cc', str(self.source), '-o', str(self.dist / 'bin/mpv'), *flags],
            check=True,
            capture_output=True,
        )

    def archive(self, traversal=False):
        raw = io.BytesIO()
        with tarfile.open(fileobj=raw, mode='w') as archive:
            archive.add(self.dist / 'bin', arcname='bin')
            archive.add(self.dist / 'lib', arcname='lib')
            if traversal:
                entry = tarfile.TarInfo('../escape')
                entry.size = 1
                archive.addfile(entry, io.BytesIO(b'x'))
        packed = subprocess.run(['zstd', '-q', '-c'], input=raw.getvalue(), check=True, capture_output=True).stdout
        path = self.root / 'runtime.tar.zst'
        path.write_bytes(packed)
        Path(str(path) + '.sha256').write_text(hashlib.sha256(packed).hexdigest() + '  ' + path.name + '\n')
        return path

    def verify(self, expected, *, traversal=False, static_pass=False):
        result = subprocess.run(
            [
                'bash',
                str(self.root / 'scripts/verify-artifact.sh'),
                'audit',
                str(self.archive(traversal)),
            ],
            capture_output=True,
            text=True,
            timeout=20,
        )
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn(expected, output)
        if not static_pass:
            self.assertNotIn('TEST_RUNTIME_REACHED', output)

    def test_valid_static_contract_reaches_runtime(self):
        self.verify('TEST_RUNTIME_REACHED', static_pass=True)

    def test_host_zlib_cannot_complete_archive(self):
        self.compile('-DNEED_ZLIB', '-Wl,-l:libz.so.1')
        self.verify("Missing bundled dependency 'libz.so.1'")

    def test_non_elf_library(self):
        (self.dist / 'lib/libextra.so').write_text('source code or log')
        self.verify('Artifact file is not ELF')

    def test_nested_library_directory(self):
        (self.dist / 'lib/build').mkdir()
        self.verify('only flat shared-library files')

    def test_source_file(self):
        (self.dist / 'lib/source.c').write_text('int unused;')
        self.verify('only flat shared-library files')

    def test_loader_name(self):
        shutil.copy2(self.dist / 'bin/mpv', self.dist / 'lib/ld-linux-x86-64.so.2')
        self.verify('Forbidden bundled')

    def test_nsl1_name(self):
        shutil.copy2(self.dist / 'bin/mpv', self.dist / 'lib/libnsl.so.1')
        self.verify('Forbidden bundled')

    def test_nsl_system_runtime_is_exact(self):
        result = subprocess.run(
            [
                'bash',
                '-c',
                'source "$1"; system_runtime_name libnsl.so.1 && ! system_runtime_name libnsl.so.2',
                'bash',
                str(self.root / 'scripts/system-runtime.sh'),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_library_link_outside_lib(self):
        (self.dist / 'lib/libbad.so').symlink_to('../bin/mpv')
        self.verify('symlink escapes lib/')

    def test_rpath(self):
        self.compile('-Wl,--disable-new-dtags,-rpath,/usr/lib')
        self.verify('DT_RPATH is not permitted')

    def test_runpath_escape(self):
        self.compile('-Wl,-rpath,$ORIGIN/../../outside')
        self.verify('RUNPATH escapes artifact')

    def test_origin_runpath(self):
        self.compile('-Wl,-rpath,$ORIGIN/../lib')
        self.verify('TEST_RUNTIME_REACHED', static_pass=True)

    def test_wrong_machine(self):
        path = self.dist / 'bin/mpv'
        data = bytearray(path.read_bytes())
        data[18:20] = (183).to_bytes(2, 'little')
        path.write_bytes(data)
        self.verify('Wrong ELF architecture')

    def test_glibc_ceiling(self):
        path = self.root / 'targets/audit/target.env'
        path.write_text(path.read_text().replace('999.0', '2.0'))
        self.verify('above configured GLIBC_BASELINE')

    def test_archive_traversal(self):
        self.verify('Unsafe archive member path', traversal=True)
        self.assertFalse((self.root / 'escape').exists())

    def test_symbol_version_mismatch(self):
        source = self.root / 'library.c'
        source.write_text('int audit(void) { return 1; }\n')
        script = self.root / 'library.map'
        library = self.dist / 'lib/libaudit.so.1'

        def build(version):
            script.write_text(version + ' { global: audit; local: *; };\n')
            subprocess.run(
                [
                    'cc',
                    '-shared',
                    '-fPIC',
                    str(source),
                    '-Wl,-soname,libaudit.so.1',
                    '-Wl,--version-script=' + str(script),
                    '-o',
                    str(library),
                ],
                check=True,
                capture_output=True,
            )
        build('AUDIT_1')
        self.compile(
            '-DNEED_AUDIT',
            '-L' + str(library.parent),
            '-Wl,-l:libaudit.so.1',
        )
        self.verify('TEST_RUNTIME_REACHED', static_pass=True)
        build('AUDIT_2')
        self.verify("does not provide version 'AUDIT_1'")


if __name__ == '__main__':
    unittest.main(verbosity=2)
