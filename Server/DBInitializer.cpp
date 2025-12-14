#include "DBInitializer.h"
#include <iostream>


DBInitializer::DBInitializer(const std::string& dbPath) : dbPath_(dbPath) {}
DBInitializer::~DBInitializer() { if (db_) sqlite3_close(db_); }

bool DBInitializer::exec_sql(const std::string& sql) {
    char* errMsg = nullptr;
    if (sqlite3_exec(db_, sql.c_str(), nullptr, nullptr, &errMsg) != SQLITE_OK) {
        std::cerr << "SQL error: " << (errMsg ? errMsg : "") << "\n";
        sqlite3_free(errMsg);
        return false;
    }
    return true;
}

bool DBInitializer::init() {
    if (sqlite3_open(dbPath_.c_str(), &db_) != SQLITE_OK) {
        std::cerr << "Cannot open DB: " << sqlite3_errmsg(db_) << "\n";
        return false;
    }
    if (!exec_sql("PRAGMA foreign_keys = ON;")) return false;
    exec_sql("BEGIN TRANSACTION;");

    bool ok = true;
    ok &= exec_sql(R"SQL(
      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        avatar TEXT,
        passwordHash TEXT NOT NULL,
        token TEXT
      );
    )SQL");



    ok &= exec_sql(R"SQL(
      INSERT OR IGNORE INTO users (id, name, avatar, passwordHash) VALUES -- OR IGNORE Ö÷¼ü³åÍ»Ôò²åÈëºöÂÔ 
      ('u1', 'Alice', 'https://example.com/a.png', '1'),
      ('u2', 'Bob',   'https://example.com/b.png', '2');
    )SQL");

    ok &= exec_sql(R"SQL(
      CREATE TABLE IF NOT EXISTS chats (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        participantIds TEXT NOT NULL,
        lastMessage TEXT,
        lastMessageTime INTEGER,
        unreadCount INTEGER DEFAULT 0
      );
    )SQL");

    ok &= exec_sql(R"SQL(
      CREATE TABLE IF NOT EXISTS messages (
        id TEXT PRIMARY KEY,
        chatId TEXT NOT NULL,
        senderId TEXT NOT NULL,
        senderName TEXT NOT NULL,
        type INTEGER NOT NULL,
        content TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        isRead INTEGER DEFAULT 0,
        FOREIGN KEY (chatId) REFERENCES chats (id) ON DELETE CASCADE
      );
    )SQL");

    ok &= exec_sql(R"SQL(
      CREATE INDEX IF NOT EXISTS idx_messages_chatId
      ON messages(chatId, timestamp DESC);
    )SQL");

    //ok &= exec_sql(R"SQL(
    //  CREATE TABLE IF NOT EXISTS image_files (
    //    id TEXT PRIMARY KEY,
    //    messageId TEXT NOT NULL,
    //    filePath TEXT NOT NULL,
    //    fileName TEXT NOT NULL,
    //    fileSize INTEGER NOT NULL,
    //    width INTEGER,
    //    height INTEGER,
    //    createdAt INTEGER NOT NULL,
    //    FOREIGN KEY (messageId) REFERENCES messages (id) ON DELETE CASCADE
    //  );
    //)SQL");

    ok &= exec_sql(R"SQL(
      CREATE TABLE IF NOT EXISTS contacts (
        id INTEGER PRIMARY KEY,
        contactId1 TEXT NOT NULL,
        contactId2 TEXT NOT NULL,
        status TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        FOREIGN KEY (contactId1) REFERENCES users (id) ON DELETE CASCADE,
        FOREIGN KEY (contactId2) REFERENCES users (id) ON DELETE CASCADE
      );
    )SQL");

    if (ok) {
        exec_sql("COMMIT;");
        std::cout << "Database initialized successfully.\n";
    }
    else {
        exec_sql("ROLLBACK;");
        std::cerr << "Initialization failed. Rolled back.\n";
    }
    return ok;
}