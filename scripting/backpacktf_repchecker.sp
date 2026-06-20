#include <ripext>
#include <sdktools>

#undef REQUIRE_PLUGIN
#include <scp>
#include <sourcebanspp>

#define PLUGIN_VERSION      "1.3"
#define BPTF_IGETUSERSV3    "https://backpack.tf/api/IGetUsers/v3"
#define BPTF_IGETCURRENCIES "https://backpack.tf/api/IGetCurrencies/v1"
#define BAN_REASON_LENGTH   256
#define FBAN_NAME_LENGTH    128
#define MAX_TAG_LENGTH      64
#define API_KEY_LENGTH      64

// uncomment DEBUG to enable debug mode
// change MYSELF to your steam ID and TARGET to a banned user's steam ID to test features when DEBUG is enabled
// #define DEBUG
#define DEBUG_ID_MYSELF     "76561198073823378"
#define DEBUG_ID_TARGET     "76561198813185461"

enum struct FeatureBan
{
    char name[FBAN_NAME_LENGTH];
    char reason[BAN_REASON_LENGTH];
    int startTime;
    int endTime;
}

enum struct PlayerData
{
    int timeRetrieved; // could use current_time key, but will use server time to avoid inconsistencies

    char userName[MAX_NAME_LENGTH];
    float backpackValue;
    int lastUpdated;
    int positiveTrust;
    int negativeTrust;

    bool siteBanned;
    char siteBanReason[BAN_REASON_LENGTH];
    int siteBanStart;
    int siteBanEnd;

    ArrayList featureBans;
    void init()
    {
        this.featureBans = new ArrayList(sizeof(FeatureBan));
    }
    void reset()
    {
        delete this.featureBans;
    }
}

enum PunishmentType
{
    PType_None = 0,
    PType_TempSiteBan,
    PType_PermSiteBan,
    PType_NegativeTrust,
    PType_TempFeatureBan,
    PType_PermFeatureBan
}

ArrayStack g_SteamIDs;
Handle g_APITimer = INVALID_HANDLE;

StringMap g_PlayerData;

PunishmentType g_PlayerTagType[MAXPLAYERS + 1];

ConVar cvarTimerInterval;
ConVar cvarPlayerRejoinRefreshDataInterval;
ConVar cvarBptfApiKey;

ConVar cvarTempSiteBanDealMethod;
ConVar cvarTempSiteBanTag;
ConVar cvarTempSiteBanTagColor;

ConVar cvarPermSiteBanDealMethod;
ConVar cvarPermSiteBanTag;
ConVar cvarPermSiteBanTagColor;

ConVar cvarTempFeatureBanDealMethod;
ConVar cvarTempFeatureBanTag;
ConVar cvarTempFeatureBanTagColor;

ConVar cvarPermFeatureBanDealMethod;
ConVar cvarPermFeatureBanTag;
ConVar cvarPermFeatureBanTagColor;

ConVar cvarNegativeTrustThreshold;
ConVar cvarNegativeTrustDealMethod;
ConVar cvarNegativeTrustTag;
ConVar cvarNegativeTrustTagColor;

KeyValues g_KvOverrides;

float g_KeyRate = -1.0;

public Plugin myinfo =
{
    name = "Backpack.TF Trust/Ban Checker",
    author = "bolt",
    description = "Checks users' trust/ban status on backpack.tf",
    version = PLUGIN_VERSION,
    url = "https://backpack.tf"
};

public void OnPluginStart()
{
    g_SteamIDs = CreateStack(MAX_AUTHID_LENGTH);
    g_PlayerData = new StringMap();

    // load user overrides
    LoadOverrides();

    // General cvars
    cvarTimerInterval = CreateConVar("bptf_api_timer_interval", "4.0",
        "How long to wait, in seconds, before sending all client Steam IDs to the BPTF API in a batch.");

    cvarPlayerRejoinRefreshDataInterval = CreateConVar("bptf_player_rejoin_refresh_data_interval", "600",
        "If we've already retrieved a player's data before and they leave the server, this cvar controls how old their data must be, in seconds, for us to consider reacquiring it from the API");

    cvarBptfApiKey = CreateConVar("bptf_api_key", "",
        "[OPTIONAL] Backpack.TF API key, used to acquire the current refined-key rate to prettify backpack value in sm_rep", FCVAR_PROTECTED);

    // Temp site ban cvars
    cvarTempSiteBanDealMethod = CreateConVar("bptf_temp_site_ban_deal_method", "1", 
        "How to deal with users who are temporarily site banned from backpack.tf: \n\
        0 = Disabled \n\
        1 = Tag banned user and warn other users in chat (requires Custom Chat Colors) \n\
        2 = Kick user \n\
        3 = Ban user");
    cvarTempSiteBanTag = CreateConVar("bptf_temp_site_ban_tag", "[BPTF BAN]", 
        "Chat tag for users who are temporarily site banned from backpack.tf");
    cvarTempSiteBanTagColor = CreateConVar("bptf_temp_site_ban_tag_color", "F09A3F",
        "Chat tag color for users who are temporarily site banned from backpack.tf");
    
    // Perm site ban cvars
    cvarPermSiteBanDealMethod = CreateConVar("bptf_perm_site_ban_deal_method", "3", 
        "How to deal with users who are permanently site banned from backpack.tf: \n\
        0 = Disabled \n\
        1 = Tag banned user and warn other users in chat (requires Custom Chat Colors) \n\
        2 = Kick user \n\
        3 = Ban user");
    cvarPermSiteBanTag = CreateConVar("bptf_perm_site_ban_tag", "[BPTF BAN]", 
        "Chat tag for users who are permanently site banned from backpack.tf");
    cvarPermSiteBanTagColor = CreateConVar("bptf_perm_site_ban_tag_color", "F09A3F",
        "Chat tag color for users who are permanently site banned from backpack.tf");
    

    // Temp feature ban cvars
    cvarTempFeatureBanDealMethod = CreateConVar("bptf_temp_feature_ban_deal_method", "1", 
        "How to deal with users who have a temporary feature ban on backpack.tf \n\
        0 = Disabled \n\
        1 = Tag banned user and warn other users in chat (requires Custom Chat Colors) \n\
        2 = Kick user \n\
        3 = Ban user");
    cvarTempFeatureBanTag = CreateConVar("bptf_temp_feature_ban_tag", "[BPTF BAN]", 
        "Chat tag for users who are temporarily feature banned from backpack.tf");
    cvarTempFeatureBanTagColor = CreateConVar("bptf_temp_feature_ban_tag_color", "F09A3F",
        "Chat tag color for users who are temporarily feature banned from backpack.tf");
    
    // Perm feature ban cvars
    cvarPermFeatureBanDealMethod = CreateConVar("bptf_perm_feature_ban_deal_method", "1", 
        "How to deal with users who have a permanent feature ban on backpack.tf \n\
        0 = Disabled \n\
        1 = Tag banned user and warn other users in chat (requires Custom Chat Colors) \n\
        2 = Kick user \n\
        3 = Ban user");
    cvarPermFeatureBanTag = CreateConVar("bptf_perm_feature_ban_tag", "[BPTF BAN]", 
        "Chat tag for users who are permanently feature banned from backpack.tf");
    cvarPermFeatureBanTagColor = CreateConVar("bptf_perm_feature_ban_tag_color", "F09A3F",
        "Chat tag color for users who are permanently feature banned from backpack.tf");
    

    // Negative trust cvars
    cvarNegativeTrustThreshold = CreateConVar("bptf_negative_trust_threshold", "2", 
        "Minimum number of negative trusts a user must have before the deal method is triggered.")
    cvarNegativeTrustDealMethod = CreateConVar("bptf_negative_trust_deal_method", "1", 
        "How to deal with users with negative trusts >= bptf_negative_trust_threshold: \n\
        0 = Disabled \n\
        1 = Tag banned user and warn other users in chat (requires Custom Chat Colors) \n\
        2 = Kick user \n\
        3 = Ban user");
    cvarNegativeTrustTag = CreateConVar("bptf_negative_trust_tag", "[BPTF -REP]", 
        "Chat tag for users with negative trusts >= bptf_negative_trust_threshold");
    cvarNegativeTrustTagColor = CreateConVar("bptf_negative_trust_color", "F09A3F",
        "Chat tag color for users with negative trusts >= bptf_negative_trust_threshold");

    
    // cmds
    RegConsoleCmd("sm_rep", Command_CheckRep, "Check a user's backpack.tf reputation & ban status");
    RegConsoleCmd("sm_baltop", Command_ValueLeaderboard, "Backpack value leaderboard of players in server");

    // push connected clients into api queue stack
    for(int i = 1; i <= MaxClients; i++)
    {
        if(IsClientAuthorized(i) && !IsClientSourceTV(i) && !IsClientReplay(i) && !IsFakeClient(i))
        {
            char steamID[MAX_AUTHID_LENGTH];
            GetClientAuthId(i, AuthId_SteamID64, steamID, sizeof(steamID));

            #if defined DEBUG
            if(StrEqual(steamID, DEBUG_ID_MYSELF))
                strcopy(steamID, sizeof(steamID), DEBUG_ID_TARGET);
            #endif

            g_SteamIDs.PushString(steamID);
        }
    }
    if(!g_SteamIDs.Empty)
    {
        g_APITimer = CreateTimer(1.0, Timer_API);
    }

    // get key rate from bptf
    char apiKey[API_KEY_LENGTH];
    cvarBptfApiKey.GetString(apiKey, sizeof(apiKey));
    if(apiKey[0] != '\0')
        GetKeyRateFromAPI();

    cvarBptfApiKey.AddChangeHook(onApiKeyChange);

    #if defined DEBUG
    // DebugTestAPI();
    #endif
}

public void OnClientPostAdminCheck(int client)
{
    if(IsClientSourceTV(client) || IsClientReplay(client) || IsFakeClient(client))
        return;

    g_PlayerTagType[client] = PType_None;

    char steamID[MAX_AUTHID_LENGTH];
    GetClientAuthId(client, AuthId_SteamID64, steamID, sizeof(steamID));

    #if defined DEBUG
    if(StrEqual(steamID, DEBUG_ID_MYSELF))
        strcopy(steamID, sizeof(steamID), DEBUG_ID_TARGET);
    #endif

    PlayerData old;
    if(g_PlayerData.GetArray(steamID, old, sizeof(old)))
    {
        int currentTime = GetTime();
        int timeRetrieved = old.timeRetrieved;
        int minRefreshInterval = cvarPlayerRejoinRefreshDataInterval.IntValue;
        if((currentTime - timeRetrieved) < minRefreshInterval)
        {
            #if defined DEBUG
            PrintToServer("[BACKPACK.TF] Data of %s is too new, not fetching", steamID);
            #endif
            return;
        }
    }

    g_SteamIDs.PushString(steamID);
    delete g_APITimer;
    g_APITimer = CreateTimer(cvarTimerInterval.FloatValue, Timer_API);
}

public void OnClientDisconnect(int client)
{
    g_PlayerTagType[client] = PType_None;
}

public Action Timer_API(Handle timer)
{
    char steamIDs[MAX_AUTHID_LENGTH * MAXPLAYERS];
    int totalWritten = 0;
    while(!g_SteamIDs.Empty)
    {
        if(totalWritten)
        {
            steamIDs[totalWritten] = ',';
            totalWritten += 1;
        }

        int currentWritten;
        g_SteamIDs.PopString(steamIDs[totalWritten], sizeof(steamIDs), currentWritten);

        totalWritten += currentWritten;
    }

    // PrintToServer(steamIDs);
    HTTPRequest request = new HTTPRequest(BPTF_IGETUSERSV3);
    request.AppendQueryParam("steamid", steamIDs);
    request.Get(GetAPIResponse);

    g_APITimer = INVALID_HANDLE;
    return Plugin_Stop;
}

void GetAPIResponse(HTTPResponse response, any value, const char[] error)
{
    if (response.Status != HTTPStatus_OK) {
        // todo
        return;
    }

    JSONObject responseJson = view_as<JSONObject>(view_as<JSONObject>(response.Data).Get("response"));

    int responseSuccess = responseJson.GetInt("success");
    if(!responseSuccess)
    {
        // todo
        return;
    }
    
    JSONObject playersJson = view_as<JSONObject>(responseJson.Get("players"));
    JSONObjectKeys steamIDKeys = playersJson.Keys();

    char steamID[MAX_AUTHID_LENGTH];
    while(steamIDKeys.ReadKey(steamID, sizeof(steamID)))
    {
        JSONObject cPlayerJson = view_as<JSONObject>(playersJson.Get(steamID));

        int playerSuccess = cPlayerJson.GetInt("success");
        if(!playerSuccess)
        {
            // todo
            delete cPlayerJson;
            continue;
        }

        PlayerData cPlayerData;
        cPlayerData.init();

        cPlayerData.timeRetrieved = GetTime();

        if(cPlayerJson.HasKey("name"))
        {
            cPlayerJson.GetString("name", cPlayerData.userName, sizeof(cPlayerData.userName));
        }

        if(cPlayerJson.HasKey("backpack_value"))
        {
            JSONObject bpValueJson = view_as<JSONObject>(cPlayerJson.Get("backpack_value"));
            cPlayerData.backpackValue = bpValueJson.GetFloat("440");
            delete bpValueJson;
        }

        if(cPlayerJson.HasKey("backpack_update")) // timestamp of last time bp was updated
        {
            JSONObject lastUpdateJson = view_as<JSONObject>(cPlayerJson.Get("backpack_update"));
            cPlayerData.lastUpdated = lastUpdateJson.GetInt("440");
            delete lastUpdateJson;
        }

        if(cPlayerJson.HasKey("backpack_tf_trust"))
        {
            JSONObject trustJson = view_as<JSONObject>(cPlayerJson.Get("backpack_tf_trust"));
            cPlayerData.positiveTrust = trustJson.GetInt("for");
            cPlayerData.negativeTrust = trustJson.GetInt("against");
            delete trustJson;
        }

        if(cPlayerJson.HasKey("backpack_tf_banned")) // site ban
        {
            JSONObject banJson = view_as<JSONObject>(cPlayerJson.Get("backpack_tf_banned"));
            cPlayerData.siteBanned = true;
            cPlayerData.siteBanStart = banJson.GetInt("start");
            cPlayerData.siteBanEnd = banJson.GetInt("end");
            banJson.GetString("reason", cPlayerData.siteBanReason, sizeof(cPlayerData.siteBanReason));
            delete banJson;
        }

        if(cPlayerJson.HasKey("backpack_tf_bans")) // feature bans
        {
            JSONObject fbanListJson = view_as<JSONObject>(cPlayerJson.Get("backpack_tf_bans"));
            JSONObjectKeys fbanKeys = fbanListJson.Keys();

            char fbanKey[64];
            while(fbanKeys.ReadKey(fbanKey, sizeof(fbanKey)))
            {
                JSONObject fbanJson = view_as<JSONObject>(fbanListJson.Get(fbanKey));

                FeatureBan fban;
                fbanJson.GetString("typeString", fban.name, sizeof(fban.name));
                fbanJson.GetString("reason", fban.reason, sizeof(fban.reason));
                fban.startTime = fbanJson.GetInt("start");
                fban.endTime = fbanJson.GetInt("end");

                cPlayerData.featureBans.PushArray(fban);
                delete fbanJson;
            }
            delete fbanKeys;
            delete fbanListJson;
        }
        
        PlayerData old;
        if(g_PlayerData.GetArray(steamID, old, sizeof(old)))
            old.reset();

        g_PlayerData.SetArray(steamID, cPlayerData, sizeof(cPlayerData));
        PostRepCheck(steamID);

        #if defined DEBUG
        PrintPlayerData(steamID);
        #endif

        delete cPlayerJson;
    }

    delete responseJson;
    delete playersJson;
    delete steamIDKeys;
}

void PostRepCheck(const char[] steamID)
{
    PlayerData data;
    if(!g_PlayerData.GetArray(steamID, data, sizeof(data)))
        return;
    
    int client = 0;
    for(int i = 1; i <= MaxClients; i++)
    {
        if(IsClientAuthorized(i))
        {
            char iID[MAX_AUTHID_LENGTH];
            GetClientAuthId(i, AuthId_SteamID64, iID, sizeof(iID));
            if(StrEqual(steamID, iID))
            {
                client = i;
                break;
            }

            #if defined DEBUG
            if(StrEqual(iID, "76561198073823378"))
            {
                client = i;
                break;
            }
            #endif
        }
    }
    if(!client) return;
    
    if(data.siteBanned)
    {
        bool permSiteBan = data.siteBanEnd == -1;
        int dealMethod =  permSiteBan ? cvarPermSiteBanDealMethod.IntValue : cvarTempSiteBanDealMethod.IntValue;
        int override = GetDealMethodOverride(steamID, permSiteBan ? PType_PermSiteBan : PType_TempSiteBan);
        if(override != -1)
            dealMethod = override;
        switch(dealMethod)
        {
            case 1:
            {
                PrintToChatAll("\x07FF4040[WARNING]\x01 %s is \x07FF4040site-banned\x01 from backpack.tf!", data.userName);
                PrintToServer("[BACKPACK.TF] User %s is site-banned from backpack.tf. Warning players and attempting to tag.", data.userName);

                if(permSiteBan)
                    g_PlayerTagType[client] = PType_PermSiteBan;
                else
                    g_PlayerTagType[client] = PType_TempSiteBan;
                    
                // SetClientChatTag(client, g_PlayerTagType[client]);
            }
            case 2:
            {
                PrintToChatAll("\x07FF4040[WARNING]\x01 %s is \x07FF4040site-banned\x01 from backpack.tf and has been kicked from the server!", data.userName);
                PrintToServer("[BACKPACK.TF] User %s is site-banned from backpack.tf. Kicking...", data.userName);
                KickClient(client, "Player is site-banned from backpack.tf. Contact the server admin if this is an error.");
            }
            case 3:
            {
                PrintToChatAll("\x07FF4040[WARNING]\x01 %s is \x07FF4040site-banned\x01 from backpack.tf and has been banned from the server!", data.userName);
                int banDuration = permSiteBan ? 0 : (data.siteBanEnd - GetTime()) / 60;
                if(GetFeatureStatus(FeatureType_Native, "SBPP_BanPlayer") == FeatureStatus_Available)
                {
                    PrintToServer("[BACKPACK.TF] User %s is site-banned from backpack.tf. Banning via SB++... (duration: %d)", data.userName, banDuration);
                    SBPP_BanPlayer(0, client, banDuration, 
                        "Player is site-banned from backpack.tf. Contact the server admin if this is an error or if your ban status changes in the future.");
                }
                else
                {
                    PrintToServer("[BACKPACK.TF] User %s is site-banned from backpack.tf. Banning via default SRCDS ban... (duration: %d)", data.userName, banDuration);
                    BanClient(client, banDuration, BANFLAG_AUTHID, 
                        "Player is site-banned from backpack.tf. Contact the server admin if this is an error or if your ban status changes in the future.", 
                        "Player is site-banned from backpack.tf. Contact the server admin if this is an error or if your ban status changes in the future.");
                }
            }
        }
    }

    if(data.featureBans.Length)
    {
        int longestBan = 0;
        for(int i = 0; i < data.featureBans.Length; i++)
        {
            FeatureBan fban; 
            data.featureBans.GetArray(i, fban, sizeof(fban));
            if(fban.endTime == -1)
            {
                longestBan = -1;
                break;
            }
            else if(fban.endTime > longestBan)
                longestBan = fban.endTime;
        }

        bool permFeatureBan = longestBan == -1;
        int dealMethod = permFeatureBan ? cvarPermFeatureBanDealMethod.IntValue : cvarTempFeatureBanDealMethod.IntValue;
        int override = GetDealMethodOverride(steamID, permFeatureBan ? PType_PermFeatureBan : PType_TempFeatureBan);
        if(override != -1)
            dealMethod = override;
        switch(dealMethod)
        {
            case 1:
            {
                PrintToChatAll("\x07FF4040[WARNING]\x01 %s is \x07FF4040feature-banned\x01 from backpack.tf!", data.userName);
                PrintToServer("[BACKPACK.TF] User %s is feature-banned from backpack.tf. Warning players and attempting to tag.", data.userName);
                
                if(g_PlayerTagType[client] == PType_None)
                {
                    if(permFeatureBan)
                        g_PlayerTagType[client] = PType_PermFeatureBan;
                    else
                        g_PlayerTagType[client] = PType_TempFeatureBan;
                    
                    // SetClientChatTag(client, g_PlayerTagType[client]);
                }
            }
            case 2:
            {
                PrintToChatAll("\x07FF4040[WARNING]\x01 %s is \x07FF4040feature-banned\x01 from backpack.tf and has been kicked from the server!", data.userName);
                PrintToServer("[BACKPACK.TF] User %s is feature-banned from backpack.tf. Kicking...", data.userName);
                KickClient(client, "Player is feature-banned from backpack.tf. Contact the server admin if this is an error.");
            }
            case 3:
            {
                PrintToChatAll("\x07FF4040[WARNING]\x01 %s is \x07FF4040feature-banned\x01 from backpack.tf and has been banned from the server!", data.userName);
                int banDuration = permFeatureBan ? 0 : (longestBan - GetTime()) / 60;
                PrintToServer("[BACKPACK.TF] User %s is feature-banned from backpack.tf. Banning... (duration: %d)", data.userName, banDuration);
                if(GetFeatureStatus(FeatureType_Native, "SBPP_BanPlayer") == FeatureStatus_Available)
                    SBPP_BanPlayer(0, client, banDuration, 
                        "Player is feature-banned from backpack.tf. Contact the server admin if this is an error or if your ban status changes in the future.");
                else
                    BanClient(client, banDuration, BANFLAG_AUTHID, 
                        "Player is feature-banned from backpack.tf. Contact the server admin if this is an error or if your ban status changes in the future.", 
                        "Player is feature-banned from backpack.tf. Contact the server admin if this is an error or if your ban status changes in the future.");
            }
        }
    }
    
    if(data.negativeTrust >= cvarNegativeTrustThreshold.IntValue)
    {
        int dealMethod = cvarNegativeTrustDealMethod.IntValue;
        int override = GetDealMethodOverride(steamID, PType_NegativeTrust);
        if(override != -1)
            dealMethod = override;
        switch(dealMethod)
        {
            case 1:
            {
                if(!data.positiveTrust)
                    PrintToChatAll("\x07FF4040[WARNING]\x01 %s has \x07FF4040%d negative trusts\x01 on backpack.tf!", data.userName, data.negativeTrust);
                else
                    PrintToChatAll("\x07FF4040[WARNING]\x01 %s has \x07F09A3F%d negative trusts\x01 on backpack.tf!", data.userName, data.negativeTrust);
                PrintToServer("[BACKPACK.TF] User %s is has %d negative trusts on backpack.tf. Warning players and attempting to tag.", data.userName, data.negativeTrust);

                if(g_PlayerTagType[client] == PType_None)
                {
                    g_PlayerTagType[client] = PType_NegativeTrust;
                    // SetClientChatTag(client, g_PlayerTagType[client]);
                }
                
            }
            case 2:
            {
                if(!data.positiveTrust)
                    PrintToChatAll("\x07FF4040[WARNING]\x01 %s has \x07FF4040%d negative trusts\x01 on backpack.tf and has been kicked from the server!", data.userName, data.negativeTrust);
                else
                    PrintToChatAll("\x07FF4040[WARNING]\x01 %s has \x07F09A3F%d negative trusts\x01 on backpack.tf and has been kicked from the server!", data.userName, data.negativeTrust);
                PrintToServer("[BACKPACK.TF] User %s is has %d negative trusts on backpack.tf. Kicking...", data.userName, data.negativeTrust);
                KickClient(client, "Player has %d negative trusts on backpack.tf. Contact the server admin if this is an error.", data.negativeTrust);
            }
            case 3:
            {
                if(!data.positiveTrust)
                    PrintToChatAll("\x07FF4040[WARNING]\x01 %s has \x07FF4040%d negative trusts\x01 on backpack.tf and has been banned from the server!", data.userName, data.negativeTrust);
                else
                    PrintToChatAll("\x07FF4040[WARNING]\x01 %s has \x07F09A3F%d negative trusts\x01 on backpack.tf and has been banned from the server!", data.userName, data.negativeTrust);
                PrintToServer("[BACKPACK.TF] User %s is has %d negative trusts on backpack.tf. Banning...", data.userName, data.negativeTrust);
                if(GetFeatureStatus(FeatureType_Native, "SBPP_BanPlayer") == FeatureStatus_Available)
                    SBPP_BanPlayer(0, client, 0, 
                        "Player has an exceeding number of negative trusts on backpack.tf. Contact the server admin if this is an error or if your reputation status changes in the future.");
                else
                    BanClient(client, 0, BANFLAG_AUTHID, 
                        "Player has an exceeding number of negative trusts on backpack.tf. Contact the server admin if this is an error or if your reputation status changes in the future.", 
                        "Player has an exceeding number of negative trusts on backpack.tf. Contact the server admin if this is an error or if your reputation status changes in the future.");
            }
        }
    }

}

public Action Command_CheckRep(int client, int argc)
{
    int target;
    if(argc == 0)
    {
        target = GetClientAimTarget(client);
        if(target <= 0)
        {
            DisplayRepTargetMenu(client);
            return Plugin_Handled;
        }
    }
    else
    {
        char arg[MAX_NAME_LENGTH];
        GetCmdArgString(arg, sizeof(arg));
        target = FindTarget(client, arg, true, false);
        if(target == -1)
        {
            DisplayRepTargetMenu(client);
            return Plugin_Handled;
        }
    }
        
    char targetSteamID[MAX_AUTHID_LENGTH];
    GetClientAuthId(target, AuthId_SteamID64, targetSteamID, sizeof(targetSteamID));
    #if defined DEBUG
    if(StrEqual(targetSteamID, DEBUG_ID_MYSELF))
        strcopy(targetSteamID, sizeof(targetSteamID), DEBUG_ID_TARGET);
    #endif
    DisplayRepDataMenu(client, targetSteamID);

    return Plugin_Handled;
}

void DisplayRepTargetMenu(int client)
{
    Menu menu = new Menu(Handler_RepTarget);
    menu.SetTitle("Select a player to check their BPTF Rep");

    char name[MAX_NAME_LENGTH];
    char steamID[MAX_AUTHID_LENGTH];
    for(int i = 1; i <= MaxClients; i++)
    {
        if(!IsClientAuthorized(i) || IsClientSourceTV(i) || IsFakeClient(i))
            continue;
        
        GetClientName(i, name, sizeof(name));
        GetClientAuthId(i, AuthId_SteamID64, steamID, sizeof(steamID));

        menu.AddItem(steamID, name);
    }

    menu.Display(client, 0);
}

int Handler_RepTarget(Menu menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_End: delete menu;
        case MenuAction_Select:
        {
            char targetSteamID[MAX_AUTHID_LENGTH];
            menu.GetItem(param2, targetSteamID, sizeof(targetSteamID));
            DisplayRepDataMenu(param1, targetSteamID);
        }
    }
    return 0;
}

void DisplayRepDataMenu(int client, const char[] targetSteamID)
{
    PlayerData data;
    if(!g_PlayerData.GetArray(targetSteamID, data, sizeof(data)))
    {
        PrintToChat(client, "User's rep/ban status has not yet been loaded from backpack.tf");
        return;
    }
    
    Menu menu = new Menu(Handler_RepData);
    menu.SetTitle("Backpack.TF Rep Menu\nUser: %s\n ", data.userName);
    char buf[512];

    if(data.siteBanned)
        menu.AddItem("s", "!!! USER IS SITE-BANNED FROM BP.TF !!!");
    
    for(int i = 0; i < data.featureBans.Length; i++)
    {
        FeatureBan fban;
        data.featureBans.GetArray(i, fban, sizeof(fban));

        char infoBuf[16];
        IntToString(i, infoBuf, sizeof(infoBuf));
        Format(buf, sizeof(buf), "!! FEATURE-BANNED: %s", fban.name);
        menu.AddItem(infoBuf, buf);
    }

    if(g_KeyRate != -1.0)
        Format(buf, sizeof(buf), "BP Value: %.2f keys", data.backpackValue / g_KeyRate);
    else
        Format(buf, sizeof(buf), "BP Value: %.2f refined", data.backpackValue);
    menu.AddItem("", buf, ITEMDRAW_DISABLED);
    Format(buf, sizeof(buf), "Positive Trusts: %d", data.positiveTrust);
    menu.AddItem("", buf, ITEMDRAW_DISABLED);
    Format(buf, sizeof(buf), "Negative Trusts: %d", data.negativeTrust);
    menu.AddItem("", buf, ITEMDRAW_DISABLED);

    menu.AddItem(targetSteamID, "", ITEMDRAW_IGNORE);
    menu.Display(client, 0);
}

int Handler_RepData(Menu menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_End: delete menu;
        case MenuAction_Select:
        {
            char infoBuf[16];
            menu.GetItem(param2, infoBuf, sizeof(infoBuf));

            char targetSteamID[MAX_AUTHID_LENGTH];
            menu.GetItem(menu.ItemCount - 1, targetSteamID, sizeof(targetSteamID));

            if(infoBuf[0] == 's')
                DisplaySiteBanMenu(param1, targetSteamID);
            else if(IsCharNumeric(infoBuf[0]))
            {
                int fbanIndex = StringToInt(infoBuf);
                DisplayFeatureBanMenu(param1, targetSteamID, fbanIndex);
            }
                
        }
    }
    return 0;
}

void DisplaySiteBanMenu(int client, const char[] targetSteamID)
{
    PlayerData data;
    g_PlayerData.GetArray(targetSteamID, data, sizeof(data));

    Menu menu = new Menu(Handler_SiteBan);
    menu.SetTitle("Backpack.TF Rep Menu\nUser: %s\nSite Ban Information\n ", data.userName);

    char buf[512];
    Format(buf, sizeof(buf), "Reason: %s", data.siteBanReason);
    menu.AddItem("", buf, ITEMDRAW_DISABLED);
    if(data.siteBanEnd == -1)
        menu.AddItem("", "Ban Expires: Never (PERMANENT)", ITEMDRAW_DISABLED);
    else
    {
        FormatTime(buf, sizeof(buf), "%B %d, %Y %R", data.siteBanEnd);
        Format(buf, sizeof(buf), "Ban Expires: %s", buf);
        menu.AddItem("", buf, ITEMDRAW_DISABLED);
    }

    menu.AddItem(targetSteamID, "", ITEMDRAW_IGNORE);
    menu.ExitBackButton = true;
    menu.Display(client, 0);
}

int Handler_SiteBan(Menu menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_End: delete menu;
        case MenuAction_Cancel:
        {
            if(param2 == MenuCancel_ExitBack)
            {
                char targetSteamID[MAX_AUTHID_LENGTH];
                menu.GetItem(menu.ItemCount - 1, targetSteamID, sizeof(targetSteamID));
                DisplayRepDataMenu(param1, targetSteamID);
            }
        }
    }
    return 0;
}

void DisplayFeatureBanMenu(int client, const char[] targetSteamID, int fbanIndex)
{
    PlayerData data;
    g_PlayerData.GetArray(targetSteamID, data, sizeof(data));
    FeatureBan fban;
    data.featureBans.GetArray(fbanIndex, fban, sizeof(fban));

    Menu menu = new Menu(Handler_FeatureBan);
    menu.SetTitle("Backpack.TF Rep Menu\nUser: %s\nFeature Ban: %s\n ", data.userName, fban.name);

    char buf[512];
    Format(buf, sizeof(buf), "Reason: %s", fban.reason);
    menu.AddItem("", buf, ITEMDRAW_DISABLED);
    if(fban.endTime == -1)
        menu.AddItem("", "Ban Expires: Never (PERMANENT)", ITEMDRAW_DISABLED);
    else
    {
        FormatTime(buf, sizeof(buf), "%B %d, %Y %R", fban.endTime);
        Format(buf, sizeof(buf), "Ban Expires: %s", buf);
        menu.AddItem("", buf, ITEMDRAW_DISABLED);
    }

    menu.AddItem(targetSteamID, "", ITEMDRAW_IGNORE);
    menu.ExitBackButton = true;
    menu.Display(client, 0);
}

int Handler_FeatureBan(Menu menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_End: delete menu;
        case MenuAction_Cancel:
        {
            if(param2 == MenuCancel_ExitBack)
            {
                char targetSteamID[MAX_AUTHID_LENGTH];
                menu.GetItem(menu.ItemCount - 1, targetSteamID, sizeof(targetSteamID));
                DisplayRepDataMenu(param1, targetSteamID);
            }
        }
    }
    return 0;
}

public Action Command_ValueLeaderboard(int client, int argc)
{
    if(client == 0)
        return Plugin_Handled;

    ArrayList clients = new ArrayList();
    for(int i = 1; i <= MaxClients; i++)
    {
        if(!IsClientAuthorized(i) || IsClientSourceTV(i) || IsFakeClient(i))
            continue;

        char steamID[MAX_AUTHID_LENGTH];
        GetClientAuthId(i, AuthId_SteamID64, steamID, sizeof(steamID));
        if(!g_PlayerData.ContainsKey(steamID))
            continue;

        clients.Push(i);
    }

    if(clients.Length == 0)
    {
        delete clients;
        return Plugin_Handled;
    }

    SortADTArrayCustom(clients, CompareClientBackpackValues);

    Menu menu = new Menu(Handler_ValueLeaderboard);
    float totalValue = 0.0;
    bool keyRateSet = (g_KeyRate != -1.0);
    for(int i = 0; i < clients.Length; i++)
    {
        int iClient = clients.Get(i);

        char steamID[MAX_AUTHID_LENGTH];
        GetClientAuthId(iClient, AuthId_SteamID64, steamID, sizeof(steamID));
        PlayerData data;
        if(!g_PlayerData.GetArray(steamID, data, sizeof(data)))
            continue;

        totalValue += data.backpackValue;
        
        char name[MAX_NAME_LENGTH];
        GetClientName(iClient, name, sizeof(name));
        char buf[256];
        if(keyRateSet)
            Format(buf, sizeof(buf), "[#%d] %s  ---  %.2f keys", i+1, name, data.backpackValue / g_KeyRate);
        else
            Format(buf, sizeof(buf), "[#%d] %s  ---  %.2f ref", i+1, name, data.backpackValue);
        
        menu.AddItem(steamID, buf);
    }

    menu.SetTitle(
        "Top Player Backpack Values (on server) \n\
        Total Server Value: %.2f %s\n ", 
        keyRateSet ? totalValue / g_KeyRate : totalValue,
        keyRateSet ? "keys" : "ref");

    menu.Display(client, 0);

    delete clients;

    return Plugin_Handled;
}

int Handler_ValueLeaderboard(Menu menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_End: delete menu;
        case MenuAction_Select:
        {
            char steamID[MAX_AUTHID_LENGTH];
            GetMenuItem(menu, param2, steamID, sizeof(steamID));
            DisplayRepDataMenu(param1, steamID);
        }
    }
    return 0;
}

void GetKeyRateFromAPI()
{
    HTTPRequest request = new HTTPRequest(BPTF_IGETCURRENCIES);
    char apiKey[API_KEY_LENGTH];
    cvarBptfApiKey.GetString(apiKey, sizeof(apiKey))
    request.AppendQueryParam("key", apiKey);
    request.Get(PostGetKeyRate);
}

void PostGetKeyRate(HTTPResponse response, any val, const char[] error)
{
    if (response.Status != HTTPStatus_OK) {
        // todo
        return;
    }

    JSONObject responseJson = view_as<JSONObject>(view_as<JSONObject>(response.Data).Get("response"));

    int responseSuccess = responseJson.GetInt("success");
    if(!responseSuccess)
    {
        // todo
        return;
    }

    JSONObject currenciesJson   = view_as<JSONObject>(responseJson.Get("currencies"));
    JSONObject keysJson         = view_as<JSONObject>(currenciesJson.Get("keys"));
    JSONObject keysPriceJson    = view_as<JSONObject>(keysJson.Get("price"));

    float value = keysPriceJson.GetFloat("value");
    if (value == 0.0)
        value = float(keysPriceJson.GetInt("value"));

    if(keysPriceJson.HasKey("value_high"))
    {
        float valueHigh = keysPriceJson.GetFloat("value_high");
        if (valueHigh == 0.0)
            valueHigh = float(keysPriceJson.GetInt("value_high"));

        if(valueHigh != 0.0)
            value = (value + valueHigh) / 2;
    }

    g_KeyRate = value;
    PrintToChatAll("\x04[Backpack.TF]\x01 Acquired current key rate: \x04%.2f ref\x01", g_KeyRate);
}

void onApiKeyChange(ConVar convar, const char[] oldValue, const char[] newValue)
{
    char apiKey[API_KEY_LENGTH];
    convar.GetString(apiKey, sizeof(apiKey));
    if(apiKey[0] != '\0')
        GetKeyRateFromAPI();
}

void LoadOverrides()
{
    g_KvOverrides = new KeyValues("BackpackTF Overrides");
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "configs/bptf.overrides.cfg");
    g_KvOverrides.ImportFromFile(path);
}

int GetDealMethodOverride(const char[] steamid, PunishmentType ptype)
{
    g_KvOverrides.Rewind();
    
    if(!g_KvOverrides.JumpToKey(steamid))
    {
        return -1;
    }

    switch(ptype)
    {
        case PType_PermSiteBan, PType_TempSiteBan:
            return g_KvOverrides.GetNum("SiteBan", -1);
        case PType_NegativeTrust:
            return g_KvOverrides.GetNum("NegativeTrust", -1);
        case PType_PermFeatureBan, PType_TempFeatureBan:
            return g_KvOverrides.GetNum("FeatureBan", -1);
    }

    return -1;
}

stock void SetClientChatTag(int client, PunishmentType tagType)
{
    char name[MAX_NAME_LENGTH];
    char tag[MAX_TAG_LENGTH];
    switch(tagType)
    {
        case PType_TempSiteBan: cvarTempSiteBanTag.GetString(tag, sizeof(tag));
        case PType_PermSiteBan: cvarPermSiteBanTag.GetString(tag, sizeof(tag));
        case PType_NegativeTrust: cvarNegativeTrustTag.GetString(tag, sizeof(tag));
        case PType_TempFeatureBan: cvarTempFeatureBanTag.GetString(tag, sizeof(tag));
        case PType_PermFeatureBan: cvarPermFeatureBanTag.GetString(tag, sizeof(tag));
    }

    Format(name, sizeof(name), "%s %N", tag, client);
    SetClientInfo(client, "name", name);
}

public Action OnChatMessage(&author, Handle recipients, char[] name, char[] message)
{
    char tag[MAX_TAG_LENGTH];
    char tagColor[8];
    // char tagWithColor[MAX_TAG_LENGTH + 16];
    switch(g_PlayerTagType[author])
    {
        case PType_None: return Plugin_Continue;
        case PType_TempSiteBan:
        {
            cvarTempSiteBanTag.GetString(tag, sizeof(tag));
            cvarTempSiteBanTagColor.GetString(tagColor, sizeof(tagColor));
            Format(name, MAX_NAME_LENGTH, "\x07%s%s\x03 %s", tagColor, tag, name);
        }
        case PType_PermSiteBan:
        {
            cvarPermSiteBanTag.GetString(tag, sizeof(tag));
            cvarPermSiteBanTagColor.GetString(tagColor, sizeof(tagColor));
            Format(name, MAX_NAME_LENGTH, "\x07%s%s\x03 %s", tagColor, tag, name);
        }
        case PType_TempFeatureBan:
        {
            cvarTempFeatureBanTag.GetString(tag, sizeof(tag));
            cvarTempFeatureBanTagColor.GetString(tagColor, sizeof(tagColor));
            Format(name, MAX_NAME_LENGTH, "\x07%s%s\x03 %s", tagColor, tag, name);
        }
        case PType_PermFeatureBan:
        {
            cvarPermFeatureBanTag.GetString(tag, sizeof(tag));
            cvarPermFeatureBanTagColor.GetString(tagColor, sizeof(tagColor));
            Format(name, MAX_NAME_LENGTH, "\x07%s%s\x03 %s", tagColor, tag, name);
        }
        case PType_NegativeTrust:
        {
            cvarNegativeTrustTag.GetString(tag, sizeof(tag));
            cvarNegativeTrustTagColor.GetString(tagColor, sizeof(tagColor));
            Format(name, MAX_NAME_LENGTH, "\x07%s%s\x03 %s", tagColor, tag, name);
        }
    }
}

int CompareClientBackpackValues(int idx1, int idx2, Handle array, Handle hndl)
{
    int client1 = GetArrayCell(array, idx1);
    int client2 = GetArrayCell(array, idx2);
    PlayerData data1;
    PlayerData data2;
    char steamID1[MAX_AUTHID_LENGTH];
    char steamID2[MAX_AUTHID_LENGTH];
    GetClientAuthId(client1, AuthId_SteamID64, steamID1, sizeof(steamID1));
    GetClientAuthId(client2, AuthId_SteamID64, steamID2, sizeof(steamID2));
    g_PlayerData.GetArray(steamID1, data1, sizeof(data1));
    g_PlayerData.GetArray(steamID2, data2, sizeof(data2));
    if(data1.backpackValue < data2.backpackValue)
        return 1;
    else if(data1.backpackValue > data2.backpackValue)
        return -1;
    return 0;
}

// public void OnClientSettingsChanged(int client)
// {
//     if(g_PlayerTagType[client] != PType_None)
//         SetClientChatTag(client, g_PlayerTagType[client]);
// }

// debug stocks
#if defined DEBUG
stock void DebugTestAPI()
{
    g_SteamIDs.PushString("76561198073823378"); // unbanned, +trust no negative no ban
    g_SteamIDs.PushString("76561199073805105"); // unbanned, +trust no negative no ban
    g_SteamIDs.PushString("76561198813185461"); // site ban + feature ban, negative trust
    g_SteamIDs.PushString("76561198089253101"); // feature ban only
    g_SteamIDs.PushString("76561198058954965") // feature ban only
    g_APITimer = CreateTimer(1.0, Timer_API);
}

stock void PrintPlayerData(const char[] steamID)
{
    PlayerData data;
    if(!g_PlayerData.GetArray(steamID, data, sizeof(data)))
    {
        PrintToServer("No data found for %s", steamID);
        return;
    }
    PrintToServer("==== %s Player Data: ====", steamID);
    PrintToServer("BP Value: %f", data.backpackValue);
    PrintToServer("Last Updated: %d", data.lastUpdated);
    PrintToServer("Positive Trust: %d", data.positiveTrust);
    PrintToServer("Negative Trust: %d", data.negativeTrust);
    PrintToServer("Site Banned?: %d", data.siteBanned);
    PrintToServer("Site Ban Reason: %s", data.siteBanReason);
    PrintToServer("Site Ban Start: %d", data.siteBanStart);
    PrintToServer("Site Ban End: %d", data.siteBanEnd);
    PrintToServer("Feature Ban Count: %d", data.featureBans.Length);
    for(int i = 0; i < data.featureBans.Length; i++)
    {
        FeatureBan fban;
        data.featureBans.GetArray(i, fban, sizeof(fban));
        PrintToServer("== Feature Ban %d ==", i);
        PrintToServer("Name: %s", fban.name);
        PrintToServer("Reason: %s", fban.reason);
        PrintToServer("Start: %d", fban.startTime);
        PrintToServer("End: %d", fban.endTime);
    }
}
#endif