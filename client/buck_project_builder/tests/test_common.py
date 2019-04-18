# Copyright (c) 2019-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

from typing import List, Optional

from ..build_target import BuildTarget
from ..filesystem import Sources


def base(
    name: str,
    dependencies: Optional[List[str]] = None,
    sources: Optional[Sources] = None,
    base_module: Optional[str] = None,
) -> BuildTarget.BaseInformation:
    return BuildTarget.BaseInformation(
        {}, name, dependencies or [], sources or Sources(), base_module
    )
