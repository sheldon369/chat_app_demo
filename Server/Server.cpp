// Server.cpp: 定义应用程序的入口点。
//


#include "Server.h"
#include "DBInitializer.h"
#include <httplib.h>
#include <iostream>
#include "userHandler.h"

using namespace std;



int main() {
    DBInitializer dbInit("chat.db");
    if (!dbInit.init()) {
        std::cerr << "DB init failed\n";
        return 1;
    }

    httplib::Server srv;

    srv.set_mount_point("/avatars", "./public/avatars");
    srv.set_mount_point("/uploads", "./uploads");


    register_user_routes(srv, dbInit.db());
    register_contacts_route(srv, dbInit.db());
	register_chats_route(srv, dbInit.db());
	register_realtime_routes(srv, dbInit.db());

    const char* host = "0.0.0.0";
    int port = 8080;
    std::cout << "Server listening on " << host << ":" << port << "\n";
    srv.listen(host, port);
    return 0;
}