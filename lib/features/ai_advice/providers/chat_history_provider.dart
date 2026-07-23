import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../../shared/models/chat_session_model.dart';
import '../../../shared/services/local_storage_service.dart';
import '../../../shared/services/supabase_service.dart';

class ChatHistoryProvider extends ChangeNotifier {
  final _local = LocalStorageService.instance;
  final _db = SupabaseService.instance;
  final _uuid = const Uuid();

  List<ChatSessionModel> _sessions = [];
  bool _isLoading = false;

  List<ChatSessionModel> get sessions => _sessions;
  bool get isLoading => _isLoading;

  /// Local-first, same pattern as loans/savings goals: read the cache
  /// instantly, only reach for Supabase when nothing has ever been cached
  /// locally.
  Future<void> load() async {
    _isLoading = true;
    notifyListeners();
    var sessions = _local.getChatSessions();
    if (sessions.isEmpty && _db.isLoggedIn) {
      try {
        final cloud = await _db.getChatSessions();
        if (cloud.isNotEmpty) {
          await _local.replaceChatSessions(cloud);
          sessions = _local.getChatSessions();
        }
      } catch (_) {
        // Offline or nothing to recover — fall through with local (still empty).
      }
    }
    _sessions = sessions;
    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadIfNeeded() async {
    if (_sessions.isEmpty && !_isLoading) await load();
  }

  /// Derives a short title from the first user message, same convention as
  /// ChatGPT/Claude auto-titling a new conversation.
  String titleFrom(String firstUserMessage) {
    final trimmed = firstUserMessage.trim();
    if (trimmed.length <= 40) return trimmed;
    return '${trimmed.substring(0, 40).trim()}...';
  }

  /// Creates a new session for the given exchange, or updates the existing
  /// one if [existingId] is provided. Returns the session's id so the
  /// caller can keep appending to the same session as the conversation
  /// continues.
  Future<String> saveExchange({
    required String? existingId,
    required String userId,
    required List<ChatMessageRecord> messages,
  }) async {
    final now = DateTime.now();
    ChatSessionModel session;
    final idx = existingId == null
        ? -1
        : _sessions.indexWhere((s) => s.id == existingId);

    if (idx != -1) {
      session = _sessions[idx].copyWith(messages: messages, updatedAt: now);
      _sessions[idx] = session;
    } else {
      session = ChatSessionModel(
        id: existingId ?? _uuid.v4(),
        userId: userId,
        title: titleFrom(
          messages.firstWhere((m) => m.isUser, orElse: () => messages.first).text,
        ),
        messages: messages,
        createdAt: now,
        updatedAt: now,
      );
      _sessions.insert(0, session);
    }
    _sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    notifyListeners();

    await _local.upsertChatSession(session);
    final isNew = idx == -1;
    (isNew ? _db.insertChatSession(session) : _db.updateChatSession(session))
        .then((saved) {
          final i = _sessions.indexWhere((s) => s.id == session.id);
          if (i != -1) _sessions[i] = saved;
          _local.upsertChatSession(saved);
          notifyListeners();
        })
        .catchError((_) {
          // Offline — the local save above already stands as-is.
        });

    return session.id;
  }

  Future<void> toggleStar(String id) async {
    final idx = _sessions.indexWhere((s) => s.id == id);
    if (idx == -1) return;
    final updated = _sessions[idx].copyWith(
      isStarred: !_sessions[idx].isStarred,
    );
    _sessions[idx] = updated;
    notifyListeners();
    await _local.upsertChatSession(updated);
    _db.updateChatSession(updated).catchError((_) => updated);
  }

  Future<void> delete(String id) async {
    _sessions.removeWhere((s) => s.id == id);
    notifyListeners();
    await _local.deleteChatSession(id);
    _db.deleteChatSession(id).catchError((_) {});
  }
}
