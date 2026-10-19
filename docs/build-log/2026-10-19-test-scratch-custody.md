# Scratch custody test prerequisite

This change supplies the independent scratch owner and its four isolated test cases before the dormant native/generic foundation. These are test utilities; production imports, native source, installation, fingerprints, calibration and activation stay as they are.

The helper retains original ancestor, directory, leaf and task custody under one absolute deadline. Controls cover sealed bytes and name identity, create-only writes, independent cleanup causes, deadline expiry and admission before each filesystem operation. An expired or unresolved owner retains custody rather than accepting late success or starting replacement cleanup.

tests/test-dormant-scratch.ps1 uses the existing main runner to launch each case in a fresh Windows process. The child bootstrap verifies its actual executable, PowerShell version and .NET major before importing a helper. Each child must exit successfully with actual process-tree retirement.

Run the launcher normally for the installed runtime. To check the 7.2 floor fixtures, run the launcher under the current runtime and pass -FixtureExecutable ABSOLUTE_7_2_PWSH_PATH -ExpectedFixtureVersion 7.2.24 -ExpectedDotnetMajor 6. This proves the floor fixture children. The unchanged main native initializer has a known .NET 6 compilation failure, so this does not claim that the controller or complete main suite passes on 7.2. Fix inherited compatibility failures before activation.

The seven existing helper/control files are copied byte-for-byte from the locally committed dormant foundation. That branch and its review history remain preserved. After this prerequisite merges, reconcile that branch with main and continue its existing local review state using fresh combined verification. No donor test result or earlier verdict approves that later artifact.

Deadline-fault controls report intentionally retained original scratch paths in stdout. They do not perform a path sweep after expiry or claim every filesystem root was removed.
