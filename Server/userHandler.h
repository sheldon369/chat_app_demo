#pragma once
#include <httplib.h>
#include <sqlite3.h>
#include <mutex>
#include <unordered_map>
#include <vector>
#include <bcrypt.h>
#include <string>




// 挂载用户相关的 HTTP 路由
void register_user_routes(httplib::Server& srv, sqlite3* db);

void register_contacts_route(httplib::Server& srv, sqlite3* db);

void register_chats_route(httplib::Server& srv, sqlite3* db);

void register_realtime_routes(httplib::Server& srv, sqlite3* db);

std::string current_uid(const httplib::Request& req);