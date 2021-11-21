import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:rush_cli/commands/build_command/helpers/compute.dart';
import 'package:rush_cli/commands/build_command/models/rush_yaml.dart';
import 'package:rush_cli/helpers/cmd_utils.dart';
import 'package:rush_cli/helpers/process_streamer.dart';
import 'package:rush_prompt/rush_prompt.dart';

class Desugarer {
  final String _cd;
  final String _dataDir;

  Desugarer(this._cd, this._dataDir);

  /// Desugars the extension files and dependencies making them
  /// compatible with Android API level < 26.
  Future<void> run(String org, RushYaml yaml, BuildStep step) async {
    final desugarDeps = yaml.build?.desugar?.desugar_deps ?? false;
    final deps =
        desugarDeps ? _depsToBeDesugared(org, yaml.deps ?? []) : <String>[];

    // Here, all the desugar process' futures are stored for them
    // to get executed in parallel by the [Future.wait] method.
    final desugarFutures = <Future<ProcessResult>>[];

    // This is where all previously desugared deps of the extension
    // are stored. They are reused between builds.
    final desugarStore =
        Directory(p.join(_dataDir, 'workspaces', org, 'files', 'desugar'))
          ..createSync(recursive: true);

    for (final el in deps) {
      String fName = el;
      final output = p.join(desugarStore.path, p.basename(fName));
      final args = _DesugarArgs(
        cd: _cd,
        dataDir: _dataDir,
        input: fName,
        output: output,
        org: org,
      );
      desugarFutures.add(compute(_desugar, args));
    }

    // Desugar extension classes
    final classesDir = p.join(_dataDir, 'workspaces', org, 'classes');
    desugarFutures.add(compute(
        _desugar,
        _DesugarArgs(
          cd: _cd,
          dataDir: _dataDir,
          input: classesDir,
          output: classesDir,
          org: org,
        )));

    final results = await Future.wait(desugarFutures);

    final store = ErrWarnStore();
    for (final result in results) {
      store.incErrors(result.store.getErrors);
      store.incWarnings(result.store.getWarnings);
    }

    if (results.any((el) => el.result == Result.error)) {
      throw Exception();
    }
  }

  /// Returns a list of extension dependencies that are to be desugared.
  List<String> _depsToBeDesugared(String org, List<String> deps) {
    final res = <String>[];

    final store =
        Directory(p.join(_dataDir, 'workspaces', org, 'files', 'desugar'))
          ..createSync(recursive: true);
    final depsDir = p.join(_cd, 'deps');

    for (final el in deps) {
      String fName = el;
      if (el.contains(':')) {
        final arr = el.split(':');
        String version = arr[2];
        String artId = arr[1];
        String packageName = arr[0];
        fName = artId + "-" + version + ".jar";
      }
      final depDes = File(p.join(store.path, fName));
      final depOrig = File(p.join(depsDir, fName));

      // Add the dep if it isn't already desugared
      if (!depDes.existsSync()) {
        res.add(depOrig.path);
        continue;
      }

      // Add the dep if it's original file is modified
      final isModified =
          depOrig.lastModifiedSync().isAfter(depDes.lastModifiedSync());
      if (isModified) {
        res.add(depOrig.path);
      }
    }

    return res;
  }

  /// Desugars the specified JAR file or a directory of class files.
  static Future<ProcessResult> _desugar(_DesugarArgs args) async {
    final desugarJar = p.join(args.dataDir, 'tools', 'other', 'desugar.jar');

    final classpath = CmdUtils.generateClasspath(
        [
          Directory(p.join(args.dataDir, 'dev-deps')),
          Directory(p.join(args.cd, 'deps'))
        ],
        relative: false,
        exclude: [p.basename(args.input)]);

    final argFile = () {
      final rtJar = p.join(args.dataDir, 'tools', 'other', 'rt.jar');

      final contents = <String>[];
      contents
        // emits META-INF/desugar_deps
        ..add('--emit_dependency_metadata_as_needed')
        // Rewrites try-with-resources statements
        ..add('--desugar_try_with_resources_if_needed')
        ..add('--copy_bridges_from_classpath')
        ..addAll(['--bootclasspath_entry', '\'$rtJar\''])
        ..addAll(['--input', '\'${args.input}\''])
        ..addAll(['--output', '\'${args.output}\'']);

      classpath.split(CmdUtils.getSeparator()).forEach((fName) {
        contents.addAll(['--classpath_entry', '\'$fName\'']);
      });

      final file = File(p.join(args.dataDir, 'workspaces', args.org, 'files',
          'desugar', p.basenameWithoutExtension(args.input) + '.rsh'));

      file.writeAsStringSync(contents.join('\n'));

      return file;
    }();

    final cmdArgs = <String>[];
    cmdArgs
      ..add('java')
      ..addAll(['-cp', desugarJar])
      ..add('com.google.devtools.build.android.desugar.Desugar')
      ..add('@${p.basename(argFile.path)}');

    // Changing the working directory to arg file's parent dir
    // because the desugar.jar doesn't allow the use of `:`
    // in file path which is a common char in Windows paths.
    final result = await ProcessStreamer.stream(cmdArgs, args.cd,
        workingDirectory: Directory(p.dirname(argFile.path)),
        trackAlreadyPrinted: true);

    if (result.result == Result.error) {
      throw Exception();
    }

    argFile.deleteSync();
    return result;
  }
}

/// Arguments of the [Desugarer._desugar] method. This class is used
/// instead of directly passing required args to that method because
/// when running a method in an [Isolate], we can only pass one arg
/// to it.
class _DesugarArgs {
  final String cd;
  final String org;
  final String input;
  final String output;
  final String dataDir;

  _DesugarArgs(
      {required this.cd,
      required this.dataDir,
      required this.input,
      required this.output,
      required this.org});
}
