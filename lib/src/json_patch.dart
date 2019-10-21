import 'dart:convert';

import 'package:collection/collection.dart';

import 'error.dart';
import 'json_pointer.dart';

/// Utility class for JSON Patch operations.
/// Can compare JSON objects or apply patches to an object.
class JsonPatch {
  /// Performs a diff-algorithm on two JSON-like objects.
  ///
  /// Returns a JSON-like [List] of JSON Patch operations to get from [oldJson] to [newJson].
  /// May throw a [JsonPatchError] if something goes wrong.
  ///
  /// See https://tools.ietf.org/html/rfc6902 for more information.
  static List<Map<String, dynamic>> diff(dynamic oldJson, dynamic newJson) {
    try {
      // If both objects are null, no patch is required.
      if (oldJson == null && newJson == null) return [];

      // If the object was either null before or set to null now, replace the value.
      if (oldJson == null || newJson == null)
        return [
          {'op': 'replace', 'path': '', 'value': newJson}
        ];

      // If the parameters are Maps, call the specialized function for objects.
      if (oldJson is Map<String, dynamic> && newJson is Map<String, dynamic>)
        return _objectDiff(oldJson, newJson);

      // If the parameters are List, call the specialized function for lists.
      if (oldJson is List && newJson is List)
        return _listDiff(oldJson, newJson);

      // If the runtime type changed, replace the value.
      if (oldJson.runtimeType != newJson.runtimeType) {
        return [
          {'op': 'replace', 'path': '', 'value': newJson}
        ];
      }

      // For primitive types, use the == operator for comparisson and replace if necessary.
      if (oldJson != newJson)
        return [
          {'op': 'replace', 'path': '', 'value': newJson}
        ];

      // No difference found.
      return [];
    } catch (e) {
      throw JsonPatchError('An unknown error occurred.');
    }
  }

  static List<Map<String, dynamic>> _objectDiff(
      Map<String, dynamic> oldJson, Map<String, dynamic> newJson) {
    final patches = <Map<String, dynamic>>[];

    // Find all child names.
    final children = Set<String>();
    children.addAll(oldJson.keys);
    children.addAll(newJson.keys);

    for (String child in children) {
      final childPointer = JsonPointer.fromSegments([child]);
      // If both objects contain the same child, perform diff on them.
      if (oldJson.containsKey(child) && newJson.containsKey(child)) {
        final childPatches = diff(oldJson[child], newJson[child]);
        // Put the child name in front of the paths.
        patches.addAll(childPatches.map((Map<String, dynamic> childPatch) {
          String path = childPatch['path'];
          final copy = Map<String, dynamic>.from(childPatch);
          copy['path'] = JsonPointer.join(
            childPointer,
            JsonPointer.fromString(path),
          ).toString();
          return copy;
        }));
        continue;
      }

      // If the child was removed, add a remove patch.
      if (oldJson.containsKey(child)) {
        patches.add({
          'op': 'remove',
          'path': childPointer.toString(),
        });
        continue;
      }

      // If the child was added, add an add patch.
      if (newJson.containsKey(child)) {
        patches.add({
          'op': 'add',
          'path': childPointer.toString(),
          'value': newJson[child]
        });
        continue;
      }
    }

    return patches;
  }

  static List<Map<String, dynamic>> _listDiff(List oldJson, List newJson) {
    // Always replace lists if the size changed (not optimal).
    if (oldJson.length != newJson.length)
      return [
        {'op': 'replace', 'path': '', 'value': newJson}
      ];
    else {
      final result = <Map<String, dynamic>>[];
      for (int i = 0; i < oldJson.length; i++) {
        final elementPatches = diff(oldJson[i], newJson[i]);
        // Put the list index in front of each path.
        result.addAll(elementPatches.map((Map<String, dynamic> elementPatch) {
          String path = elementPatch['path'];
          final copy = Map<String, dynamic>.from(elementPatch);
          copy['path'] = JsonPointer.join(
            JsonPointer.fromSegments([i.toString()]),
            JsonPointer.fromString(path),
          ).toString();
          return copy;
        }));
      }
      return result;
    }
  }

  /// Applies JSON Patch operations to a JSON-like object.
  ///
  /// Returns the result of [json] after applying each patch of [patches] in order.
  /// The original [json] object is left unchanged.
  ///
  /// If `test` operations fail, a [JsonPatchTestFailedException] is thrown.
  ///
  /// If [strict] is `false`, adding a value that already exists is equivalent to replacing it,
  /// replacing a value that does not exist is equivalent to adding it, and removing a child that
  /// does not exist from a parent is legal and does nothing. Copying or moving will replace
  /// the value at `to` if necessary.
  ///
  /// Throws a [JsonPatchError] if something goes wrong.
  ///
  /// See https://tools.ietf.org/html/rfc6902 for more information.
  static dynamic apply(dynamic json, Iterable<Map<String, dynamic>> patches,
      {bool strict = true}) {
    try {
      // Deep copy the input.
      json = _deepCopy(json);
      // Apply each patch in order.
      for (final patch in patches) {
        json = _applyOne(json, patch, strict);
      }
      return json;
    } catch (e) {
      if (e is JsonPatchError || e is JsonPatchTestFailedException) rethrow;
      throw JsonPatchError('An unknown error occurred.');
    }
  }

  static dynamic _deepCopy(dynamic source) {
    try {
      return json.decode(json.encode(source));
    } catch (e) {
      throw JsonPatchError('Argument is not JSON-encodable.');
    }
  }

  static dynamic _applyOne(
      dynamic json, Map<String, dynamic> patch, bool strict) {
    final op = patch['op'];

    // Create fake parent to easily allow changes to the root object.
    const String fakeChild = 'child';
    final fakeParent = {fakeChild: json};

    switch (op) {
      case 'add':
        final path = _extractPath(patch);
        final value = _extractValue(patch);
        final fakePath =
            JsonPointer.join(JsonPointer.fromSegments([fakeChild]), path);
        _addChild(fakeParent, fakePath, value, strict);
        return fakeParent[fakeChild];
      case 'remove':
        final path = _extractPath(patch);
        final fakePath =
            JsonPointer.join(JsonPointer.fromSegments([fakeChild]), path);
        _removeChild(fakeParent, fakePath, strict);
        return fakeParent[fakeChild];
      case 'replace':
        final path = _extractPath(patch);
        final value = _extractValue(patch);
        final fakePath =
            JsonPointer.join(JsonPointer.fromSegments([fakeChild]), path);
        _removeChild(fakeParent, fakePath, strict);
        _addChild(fakeParent, fakePath, value, strict);
        return fakeParent[fakeChild];
      case 'copy':
        final from = _extractPath(patch, 'from');
        final to = _extractPath(patch, 'to');
        final fakeTo =
            JsonPointer.join(JsonPointer.fromSegments([fakeChild]), to);
        _addChild(fakeParent, fakeTo, from.traverse(json), strict);
        return fakeParent[fakeChild];
      case 'move':
        final from = _extractPath(patch, 'from');
        final to = _extractPath(patch, 'to');
        final fakeFrom =
            JsonPointer.join(JsonPointer.fromSegments([fakeChild]), from);
        final fakeTo =
            JsonPointer.join(JsonPointer.fromSegments([fakeChild]), to);
        final value = from.traverse(json);
        _removeChild(fakeParent, fakeFrom, strict);
        _addChild(fakeParent, fakeTo, value, strict);
        return fakeParent[fakeChild];
      case 'test':
        final path = _extractPath(patch);
        final desiredValue = _extractValue(patch);
        final actualValue = path.traverse(json);
        if (!const DeepCollectionEquality().equals(desiredValue, actualValue))
          throw JsonPatchTestFailedException(patch);
        return fakeParent[fakeChild];
      default:
        throw JsonPatchError('Invalid JSON Patch operation: "$op".');
    }
  }

  static JsonPointer _extractPath(Map<String, dynamic> patch,
      [String name = 'path']) {
    if (!patch.containsKey(name))
      throw JsonPatchError('Patch field "$name" is missing.');
    if (patch[name] == null || patch[name] is! String)
      throw JsonPatchError('Invalid path "${patch[name]}".');
    return JsonPointer.fromString(patch[name]);
  }

  static dynamic _extractValue(Map<String, dynamic> patch,
      [String name = 'value']) {
    if (!patch.containsKey(name))
      throw JsonPatchError('Patch field "$name" is missing.');
    return patch[name];
  }

  static void _addChild(
      dynamic json, JsonPointer pointer, dynamic value, bool strict) {
    final parent = pointer.parent.traverse(json);
    final child = pointer.segments.last;
    if (parent is Map<String, dynamic>) {
      if (parent.containsKey(child) && strict)
        throw JsonPatchError(
            'Tried to add value that already exists. Set strict to false to allow this. $json $pointer $parent $child');
      parent[child] = value;
    } else if (parent is List) {
      if (child == '-') {
        parent.add(value);
      } else {
        int index;
        try {
          index = int.parse(child);
        } catch (e) {
          throw JsonPatchError('Could not parse array index "$child".');
        }
        if (index < 0 || index > parent.length)
          throw JsonPatchError('Array index out of bounds.');
        parent.insert(index, value);
      }
    } else {
      throw JsonPatchError(
          'Can only add child to Map<String, dynamic> or List.');
    }
  }

  static void _removeChild(dynamic json, JsonPointer pointer, bool strict) {
    final parent = pointer.parent.traverse(json);
    final child = pointer.segments.last;
    if (parent is Map<String, dynamic>) {
      if (!parent.containsKey(child) && strict)
        throw JsonPatchError(
            'Tried to remove child that does not exist. Set strict to false to allow this.');
      parent.remove(child);
    } else if (parent is List) {
      int index;
      try {
        index = int.parse(child);
      } catch (e) {
        throw JsonPatchError('Could not parse array index "$child".');
      }
      if ((index < 0 || index >= parent.length) && strict)
        throw JsonPatchError(
            'Tried to remove out of bounds array index. Set strict to false to allow this.');
      parent.removeAt(index);
    } else {
      throw JsonPatchError(
          'Can only remove child from Map<String, dynamic> or List.');
    }
  }
}
