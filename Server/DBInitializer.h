#pragma once
#include <string>
#include <sqlite3.h>

class DBInitializer {
public:
    explicit DBInitializer(const std::string& dbPath);
    ~DBInitializer();

    bool init();  // ½¨±í
    sqlite3* db() const { return db_; }

private:
    bool exec_sql(const std::string& sql);

private:
    std::string dbPath_;
    sqlite3* db_{ nullptr };
};
