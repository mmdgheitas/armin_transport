/// A region of a screen that loads its content from the server.
library;

import 'package:material_ui/material_ui.dart';

import 'feedback.dart';

/// Loads a value and shows it; while loading and after a failure it shows that instead, with a way to retry.
///
/// A new [load] is started whenever [reloadKey] changes. The state offers [AsyncBlockState.reload]
/// for reloading after a change (reach it with a [GlobalKey]).
class AsyncBlock<T> extends StatefulWidget {
  const AsyncBlock({super.key, required this.load, required this.builder, this.reloadKey, this.loadingText});

  final Future<T> Function() load;
  final Widget Function(BuildContext context, T value) builder;
  final Object? reloadKey;
  final String? loadingText;

  @override
  State<AsyncBlock<T>> createState() => AsyncBlockState<T>();
}

class AsyncBlockState<T> extends State<AsyncBlock<T>> {
  T? _value;
  bool _hasValue = false;
  Object? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(AsyncBlock<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reloadKey != oldWidget.reloadKey) {
      _hasValue = false;
      _error = null;
      _start();
    }
  }

  /// Loads again. With [quiet] the current content stays visible until the new content has arrived.
  Future<void> reload({bool quiet = false}) {
    if (!quiet || !_hasValue) {
      setState(() {
        _hasValue = false;
        _error = null;
      });
    }
    return _start();
  }

  Future<void> _start() async {
    final generation = ++_generation;
    try {
      final value = await widget.load();
      // A newer load has been started, or the screen is gone: this result is of no use any more.
      if (!mounted || generation != _generation) return;
      setState(() {
        _value = value;
        _hasValue = true;
        _error = null;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error;
        _hasValue = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) return ErrorBlock(error: error, onRetry: reload);
    if (!_hasValue) {
      final text = widget.loadingText;
      return text == null ? const LoadingBlock() : LoadingBlock(text: text);
    }
    return widget.builder(context, _value as T);
  }
}
