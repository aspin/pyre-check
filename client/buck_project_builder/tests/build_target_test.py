# Copyright (c) 2019-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import os
import shutil
import tempfile
import unittest
from unittest.mock import call, patch

from .. import build_target, filesystem
from ..build_target import (
    PythonBinary,
    PythonLibrary,
    PythonUnitTest,
    PythonWheel,
    ThriftLibrary,
)
from ..filesystem import Glob, Sources
from .test_common import base


class BuildTargetTest(unittest.TestCase):
    def test_equality(self):
        self.assertEqual(
            PythonBinary("/ROOT", "project", base("foo")),
            PythonBinary("/ROOT", "project", base("foo")),
        )
        self.assertNotEqual(
            PythonBinary("/ROOT", "project", base("foo")),
            PythonLibrary("/ROOT", "project", base("foo")),
        )
        self.assertNotEqual(
            PythonBinary("/ROOT", "project", base("foo")),
            PythonBinary("/ROOT2", "project", base("foo")),
        )
        self.assertNotEqual(
            PythonBinary("/ROOT", "project", base("foo")),
            PythonBinary("/ROOT", "project2", base("foo")),
        )
        self.assertNotEqual(
            PythonBinary("/ROOT", "project", base("foo")),
            PythonBinary("/ROOT", "project", base("food")),
        )
        self.assertEqual(
            len(
                {
                    PythonBinary("/ROOT", "project", base("foo")),
                    PythonBinary("/ROOT", "project", base("foo")),
                    PythonBinary("/ROOT2", "project", base("foo")),
                    PythonBinary("/ROOT2", "project", base("foo")),
                    PythonLibrary("/ROOT", "project", base("foo")),
                    PythonLibrary("/ROOT", "project", base("foo")),
                }
            ),
            3,
        )

    def test_build_python_binary(self):
        target = PythonBinary(
            "/ROOT",
            "project",
            base(
                "binary",
                sources=Sources(files=["a.py"], globs=[Glob(["foo/*.py"], [])]),
            ),
        )

        with patch.object(
            filesystem,
            "resolve_sources",
            return_value=["/ROOT/project/a.py", "/ROOT/project/foo/b.py"],
        ), patch.object(filesystem, "add_symbolic_link") as add_symbolic_link:
            target.build("/out")
            add_symbolic_link.assert_has_calls(
                [
                    call("/out/project/a.py", "/ROOT/project/a.py"),
                    call("/out/project/foo/b.py", "/ROOT/project/foo/b.py"),
                ]
            )

    def test_build_python_library(self):
        target = PythonLibrary(
            "/ROOT", "project", base("library", sources=Sources(files=["a.py", "b.py"]))
        )
        with patch.object(
            filesystem,
            "resolve_sources",
            return_value=["/ROOT/project/a.py", "/ROOT/project/b.py"],
        ), patch.object(filesystem, "add_symbolic_link") as add_symbolic_link:
            target.build("/out")
            add_symbolic_link.assert_has_calls(
                [
                    call("/out/project/a.py", "/ROOT/project/a.py"),
                    call("/out/project/b.py", "/ROOT/project/b.py"),
                ]
            )

        # base_module should be respected.
        target = PythonLibrary(
            "/ROOT",
            "project",
            base(
                "library",
                sources=Sources(files=["a.py", "b.py"]),
                base_module="foo.bar.baz",
            ),
        )
        with patch.object(
            filesystem,
            "resolve_sources",
            return_value=["/ROOT/project/a.py", "/ROOT/project/b.py"],
        ), patch.object(filesystem, "add_symbolic_link") as add_symbolic_link:
            target.build("/out")
            add_symbolic_link.assert_has_calls(
                [
                    call("/out/foo/bar/baz/a.py", "/ROOT/project/a.py"),
                    call("/out/foo/bar/baz/b.py", "/ROOT/project/b.py"),
                ]
            )

        # Empty base_module should also work.
        target = PythonLibrary(
            "/ROOT",
            "project",
            base("library", sources=Sources(files=["a.py", "b.py"]), base_module=""),
        )
        with patch.object(
            filesystem,
            "resolve_sources",
            return_value=["/ROOT/project/a.py", "/ROOT/project/b.py"],
        ), patch.object(filesystem, "add_symbolic_link") as add_symbolic_link:
            target.build("/out")
            add_symbolic_link.assert_has_calls(
                [
                    call("/out/a.py", "/ROOT/project/a.py"),
                    call("/out/b.py", "/ROOT/project/b.py"),
                ]
            )

    def test_build_python_unittest(self):
        target = PythonUnitTest(
            "/ROOT",
            "project",
            base("test", sources=Sources(globs=[Glob(["tests/*.py"], [])])),
        )

        with patch.object(
            filesystem,
            "resolve_sources",
            return_value=[
                "/ROOT/project/tests/test_a.py",
                "/ROOT/project/tests/test_b.py",
            ],
        ), patch.object(filesystem, "add_symbolic_link") as add_symbolic_link:
            target.build("/out")
            add_symbolic_link.assert_has_calls(
                [
                    call(
                        "/out/project/tests/test_a.py", "/ROOT/project/tests/test_a.py"
                    ),
                    call(
                        "/out/project/tests/test_b.py", "/ROOT/project/tests/test_b.py"
                    ),
                ]
            )

    @patch.object(tempfile, "TemporaryDirectory")
    @patch.object(os, "makedirs")
    def test_build_thrift_library(self, makedirs, TemporaryDirectory):
        TemporaryDirectory.return_value.__enter__.return_value = "/tmp_dir"

        with patch.object(
            filesystem, "build_thrift_stubs", return_value="/tmp_dir/gen-py"
        ) as build_thrift_stubs, patch.object(
            build_target,
            "find_python_paths",
            return_value=[
                "/tmp_dir/gen-py/project/foo/bar.pyi",
                "/tmp_dir/gen-py/project/foo/baz.pyi",
                "/tmp_dir/gen-py/project/__init__.pyi",
                "/tmp_dir/gen-py/project/foo/__init__.pyi",
            ],
        ) as find_python_paths, patch.object(
            shutil, "copy2"
        ) as copy2:
            target = ThriftLibrary(
                "/ROOT",
                "project",
                base("thrift_library"),
                ["foo/bar.thrift", "baz.thrift"],
                True,
            )
            target.build("/out")
            build_thrift_stubs.assert_called_once_with(
                "/ROOT",
                ["project/foo/bar.thrift", "project/baz.thrift"],
                "/tmp_dir",
                include_json_converters=True,
            )
            find_python_paths.assert_called_once_with("/tmp_dir/gen-py")
            copy2.assert_has_calls(
                [
                    call(
                        "/tmp_dir/gen-py/project/foo/bar.pyi",
                        "/out/project/foo/bar.pyi",
                    ),
                    call(
                        "/tmp_dir/gen-py/project/foo/baz.pyi",
                        "/out/project/foo/baz.pyi",
                    ),
                ]
            )
            self.assertEqual(copy2.call_count, 2)

        # The base_module is also taken into account by Thrift.
        with patch.object(
            filesystem, "build_thrift_stubs", return_value="/tmp_dir/gen-py"
        ) as build_thrift_stubs, patch.object(
            build_target,
            "find_python_paths",
            return_value=["/tmp_dir/gen-py/base/module/foo/bar.pyi"],
        ) as find_python_paths, patch.object(
            shutil, "copy2"
        ) as copy2:
            target = ThriftLibrary(
                "/ROOT",
                "project",
                base("thrift_library", base_module="base.module"),
                ["foo/bar.thrift", "baz.thrift"],
                True,
            )
            target.build("/out")
            build_thrift_stubs.assert_called_once_with(
                "/ROOT",
                ["project/foo/bar.thrift", "project/baz.thrift"],
                "/tmp_dir",
                include_json_converters=True,
            )
            find_python_paths.assert_called_once_with("/tmp_dir/gen-py")
            copy2.assert_called_once_with(
                "/tmp_dir/gen-py/base/module/foo/bar.pyi",
                "/out/base/module/foo/bar.pyi",
            )

        # Empty base_module and the include_json_converters flag should work.
        with patch.object(
            filesystem, "build_thrift_stubs", return_value="/tmp_dir/gen-py"
        ) as build_thrift_stubs, patch.object(
            build_target,
            "find_python_paths",
            return_value=["/tmp_dir/gen-py/foo/bar.pyi"],
        ) as find_python_paths, patch.object(
            shutil, "copy2"
        ) as copy2:
            target = ThriftLibrary(
                "/ROOT",
                "project",
                base("thrift_library", base_module=""),
                ["foo/bar.thrift", "baz.thrift"],
                False,
            )
            target.build("/out")
            build_thrift_stubs.assert_called_once_with(
                "/ROOT",
                ["project/foo/bar.thrift", "project/baz.thrift"],
                "/tmp_dir",
                include_json_converters=False,
            )
            find_python_paths.assert_called_once_with("/tmp_dir/gen-py")
            copy2.assert_called_once_with(
                "/tmp_dir/gen-py/foo/bar.pyi", "/out/foo/bar.pyi"
            )

    def test_build_python_wheel(self):
        version_url_mapping = {
            "1.0": {
                "py3-platform007": "py3-platform007_1.0_url",
                "py3-gcc-5-glibc-2.23": "py3-gcc-5-glibc-2.23_1.0_url",
            },
            "2.0": {
                "py3-platform007": "py3-platform007_2.0_url",
                "py3-gcc-5-glibc-2.23": "py3-gcc-5-glibc-2.23_2.0_url",
            },
        }
        target = PythonWheel(
            "/ROOT",
            "project",
            base("wheel"),
            {"py3-platform007": "1.0", "py3-gcc-5-glibc-2.23": "2.0"},
            version_url_mapping,
        )
        with patch.object(
            filesystem, "download_and_extract_zip_file"
        ) as download_and_extract_zip_file:
            target.build("/out")
            download_and_extract_zip_file.assert_called_with(
                "py3-platform007_1.0_url", "/out"
            )

        target = PythonWheel(
            "/ROOT",
            "project",
            base("wheel"),
            {"py3-platform007": "2.0", "py3-gcc-5-glibc-2.23": "2.0"},
            version_url_mapping,
        )
        with patch.object(
            filesystem, "download_and_extract_zip_file"
        ) as download_and_extract_zip_file:
            target.build("/out")
            download_and_extract_zip_file.assert_called_with(
                "py3-platform007_2.0_url", "/out"
            )

        target = PythonWheel(
            "/ROOT",
            "project",
            base("wheel"),
            {"py3-gcc-5-glibc-2.23": "2.0"},
            version_url_mapping,
        )
        with patch.object(
            filesystem, "download_and_extract_zip_file"
        ) as download_and_extract_zip_file:
            target.build("/out")
            download_and_extract_zip_file.assert_called_with(
                "py3-gcc-5-glibc-2.23_2.0_url", "/out"
            )

        # Raises if no platform could be found.
        target = PythonWheel(
            "/ROOT",
            "project",
            base("wheel"),
            {"py2-platform007": "2.0"},
            version_url_mapping,
        )
        self.assertRaises(ValueError, target.build, "/out")
