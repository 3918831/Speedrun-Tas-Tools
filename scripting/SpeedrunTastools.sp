//SourcePawn

/*
*	2019/10/27	Replay可转视角、虚血移速问题没有解决
*	2019/10/29	人物落地声音解决、虚血移速问题没有解决(但是解决了提出问题的想法)
*	2019/11/25	精简了所有已经用不到的代码和依赖头文件,修复多人物品掉落的崩溃问题,线性平滑加入光圈提示
*	2019/12/02	加入了Replay轨迹绘制，功能性实现轨迹周边禁止刷infecteds，但是性能不佳，修复导致游戏崩溃的问题
*	2019/12/03	加入功能：从StopFrame处直接转换为继续录制Replay,并加入该功能的开关(全局,不区分Player,不允许Bot使用)
*	2019/12/17	加入功能：多人控制，有房主进行多人同步控制，随之出现问题：自由视角功能不能正常工作
*	2020/04/02	Bug修复：
*				1.修复Replay中爬梯没有速度的问题
*				2.修复意外停止Replay的按键滞留问题
*				3.修复意外停止绘制Replay轨迹导致后台频繁报错问题
*				4.修复了过关保存Replay的判定错误导致生成空文件的问题
*				5.删除了多人模式，精简代码
*				6.人物倒地或死亡以后会停止Replay
*				7.退出菜单存在滞后问题(二次打开才有效)，暂时手动添加了退出菜单解决
*	2020/04/14	1.修改了播放Replay闲置逻辑，即使闲置replay也会继续。
*				2.改进了轨迹曲线的绘制算法，大幅节省资源
*	2020/05/04	1.Replay可以记录和播放闲置和接管动作。
*				2.加入了一个类似st_idle_anytime的开关：sm_replay_idle_anytime
*				3.尝试性修复了bot无法开门的bug
*				4.加入了OnRecordTick和OnPlayTick函数进行hook
*	2021/01/01	1.修复按键信息延迟位置信息1tick的问题
*				2.修复由于修复按键延迟特性导致的落地无声问题
*				3.加入从播放Replay状态立即转为录制状态的特性
*	2021/03/27	1.取消播放replay时的闲置，解决转录制的无故闲置问题(此bug本人未复现，为玩家反馈)
*	2021/03/28	1.加入分离已有Replay文件的功能，需先给玩家加载一个Replay，格式sm_replay_split 1 2 3
*	2021/06/12	1.加入电击器Trick调试功能，控制台str_deftrick指令控制，代替原脚本坐标映射，可直接插件完成
*	2021/08/08	1.删除电击器Trick的坐标映射计算代码，通过脚本计算或者通过地图info_landmark坐标直接计算并通过模板设置控制台变量:str_posmap_x,str_posmap_y,str_posmap_z
*	2023/01/08	1.加入一个bool开关，用于控制是否在到底情况下继续播放replay，默认是关闭。
*                        .::::.
*                      .::::::::.
*                     :::::::::::
*                  ..:::::::::::'
*               '::::::::::::'
*                 .::::::::::
*            '::::::::::::::..
*                 ..::::::::::::.
*               ``::::::::::::::::
*                ::::``:::::::::'        .:::.
*               ::::'   ':::::'       .::::::::.
*             .::::'      ::::     .:::::::'::::.
*            .:::'       :::::  .:::::::::' ':::::.
*           .::'        :::::.:::::::::'      ':::::.
*          .::'         ::::::::::::::'         ``::::.
*      ...:::           ::::::::::::'              ``::.
*     ```` ':.          ':::::::::'                  ::::..
*                        '.:::::'                    ':'````..
*                     美女保佑 永无BUG
*
*
*
*/

#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <string>
#include <keyvalues>
#include <sdkhooks>
//#include <adminmenu>

/*
	multicolors：
	https://forums.alliedmods.net/showthread.php?t=247770
*/
#include <multicolors>
#include "STR\Time.inc"
#include "STR\Menus.inc"
#include "STR\Formats.inc"
#include "STR\Vector.inc"
#include "STR\STAPlayer.inc"
#include "STR\ReplayFrame.inc"


#define L4D2_TEAM_NONE		0
#define L4D2_TEAM_SPECTATOR	1	/**< Spectators. */
#define L4D2_TEAM_SURVIVOR	2	/**< Survivors. */
#define L4D2_TEAM_INFECTED	3	/**< Infecteds. */
#define MAXCLIENTS 32
#define ITEMS_COUNT 27
#define IN_IDLE			(1 << 26)
#define IN_TAKEOVER	(1 << 27)




//static int STR_LaserSprite;
static int i_angsmooth[MAXCLIENTS + 1];							//自由视角平滑过渡递减变量
static int tickcount = 10;										//用于平滑角度的tick数量
static int preframeang;
static int Isattack[MAXCLIENTS + 1];							//2021.3.28每个玩家分配一个attack倒计数按键变量
static float f_host_timescale = 0.0;
static float preframeanglestmp[2];
static float frameanglestmp[3];
static float outviewangs[3];									//自由视角线性过渡角度变量
static float preframeangles[2];

static bool IsLinear_Transition[MAXCLIENTS + 1];				//线性平滑开关
static float pos_start[MAXCLIENTS + 1][3];						//线性平滑的位置	
static float pos_end[MAXCLIENTS + 1][3];
static float viewangles_start[MAXCLIENTS + 1][3];
static float viewangles_line[MAXCLIENTS + 1][3];				//线性过渡角度变量
static float frameangles_end[MAXCLIENTS + 1][2];
static float outpos[MAXCLIENTS + 1][3]; 						//线性插值输出位置
static float outang[MAXCLIENTS + 1][2];							//线性插值输出角度
static int linetickcount[MAXCLIENTS + 1];						//线性过渡过程中所用tick数量
static int i_linesmooth[MAXCLIENTS + 1];						//线性平滑的递减变量
static int ibuttons[MAXCLIENTS + 1];							//2021.3.28每个玩家分配一个按键变量
static int ibuttonsEx[MAXCLIENTS + 1];							//2021.3.28每个玩家分配一个按键变量
static int Trace_Line[MAXCLIENTS + 1];							//绘制移动轨迹
static bool PauseWhilePlaying[MAXCLIENTS + 1];					//播放Replay的时候暂停
static bool g_bIsFileLoad[MAXCLIENTS + 1];
static int IdleFlags[MAXCLIENTS + 1];							//闲置

//new Handle:Timer_Draw_Trace[MAXCLIENTS + 1];	
new Handle:b_ShowFrame;											//是否显示Frame的细节
new Handle:b_PlayingToRecord;									//是否从Playing转换为Record
new Handle:b_ReplayDebug;										//是否进行Debug操作
//new Handle:b_Def_Trick;										//是否打开电击器Trick调试
new Handle:b_PlayWhenIncapacitated;
new Handle:g_hTakeOverBot;
new Handle:g_hGoAwayFromKeyboard;
new Handle:g_hOnPlayTick;										//hook每个play时的tick
new Handle:g_hOnRecordTick;										//hook每个record时tick
new Handle:g_ConVar_ReplayIdleAnytime;							//允许在播replay的任意情况闲置
new Handle:g_ConVar_PosMap_x;									//电击器Trick映射坐标x分量
new Handle:g_ConVar_PosMap_y;									//电击器Trick映射坐标y分量
new Handle:g_ConVar_PosMap_z;									//电击器Trick映射坐标z分量



new const String:g_Items[ITEMS_COUNT][] =
{
	"NULL",
	"weapon_upgradepack_incendiary",
	"weapon_upgradepack_explosive",
	"weapon_pistol",
	"weapon_pistol_magnum",
	"weapon_adrenaline",
	"weapon_pain_pills",
	"weapon_vomitjar",
	"weapon_pipe_bomb",
	"weapon_molotov",
	"weapon_defibrillator",
	"weapon_first_aid_kit",
	"weapon_shotgun_chrome",
	"weapon_pumpshotgun",
	"weapon_shotgun_spas",
	"weapon_autoshotgun",
	"weapon_smg",
	"weapon_smg_silenced",
	"weapon_rifle",
	"weapon_rifle_ak47",
	"weapon_rifle_desert",
	"weapon_hunting_rifle",
	"weapon_sniper_military",
	"weapon_rifle_m60",
	"weapon_grenade_launcher",
	"weapon_chainsaw",
	"weapon_melee"
};



public Plugin myinfo = 
{
	name = "Speedrun TAS Tools(L4D2)",
	//author = "Jonah_xia(Owned by DBGaming)",
	author = "DBGaming Team",
	description = "求生之路2速跑的TAS工具.",
	version = "2.2.0612",
	url = ""
};


public void OnPluginStart()
{
	
	char dirbuf[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, dirbuf, sizeof(dirbuf), "%s", STR_RootPath);

	if (!DirExists(dirbuf))
		CreateDirectory(dirbuf, 511);

	BuildPath(Path_SM, dirbuf, sizeof(dirbuf), "%s/%s", STR_RootPath, STR_ReplayFolder);

	if (!DirExists(dirbuf))
		CreateDirectory(dirbuf, 511);

	BuildPath(Path_SM, dirbuf, sizeof(dirbuf), "%s/%s", STR_RootPath, STR_ZoneFolder);

	if (!DirExists(dirbuf))
	CreateDirectory(dirbuf, 511);

	RegConsoleCmd("sm_str", 						STR_ManageReplays);
	RegConsoleCmd("sm_loadfile", 					Cmd_loadFile);
	RegConsoleCmd("sm_replay_continue", 			Cmd_Replay_Continue);
	RegConsoleCmd("sm_replayrecord", 				Cmd_Replay_Record);
	RegConsoleCmd("sm_replaysave", 					Cmd_ReplaySave);
	RegConsoleCmd("sm_resetreplay", 				Cmd_Reset_Replay);
	RegConsoleCmd("sm_smoothreplay", 				Cmd_Smooth_Replay);
	RegConsoleCmd("sm_replaydrawtrace", 			STR_ReplayDrawTrace);
	RegConsoleCmd("sm_replaydrawtrace_posmap", 		STR_ReplayDrawTrace_PosMap);
	RegConsoleCmd("sm_replaydrawtraceclose", 		STR_ReplayCloseDrawTrace);
	RegConsoleCmd("sm_startframe", 					Cmd_Start_Frame);
	RegConsoleCmd("sm_endframe", 					Cmd_End_Frame);
	RegConsoleCmd("sm_stopframe", 					Cmd_Stop_Frame);
	RegConsoleCmd("sm_removeslot", 					Cmd_Remove_Slot);
	RegConsoleCmd("sm_replay_pause", 				Cmd_ReplayPause);
	RegConsoleCmd("sm_replay_unpause", 				Cmd_ReplayUnPause);
	RegConsoleCmd("sm_replay_split", 				Cmd_ReplaySplit);
	
	RegConsoleCmd("sm_test", 						Cmd_Test);
	//RegConsoleCmd("sm_stepforward", 				STR_StepForward);
	//RegConsoleCmd("sm_stepback", 					STR_StepBack);
	
	b_ShowFrame 				= 		CreateConVar("sm_showframe", "1", "是否在屏幕中间显示Replay细节.", FCVAR_NONE);
	//b_Def_Trick 				= 		CreateConVar("str_deftrick", "0", "电击器Trick调试开关, 1 = on, 0 = off.", FCVAR_NOTIFY);	
	b_PlayingToRecord 			= 		CreateConVar("sm_replaytorecord", "0", "从Playing转换为Record的开关.", FCVAR_NOTIFY);
	b_ReplayDebug 				= 		CreateConVar("sm_replaydebug", "0", "Replay的Debug开关(Trace是否全局透视).", FCVAR_NOTIFY);
	b_PlayWhenIncapacitated		=		CreateConVar("sm_replay_incapacitated", "0", "是否在倒地状态播放replay.", FCVAR_NOTIFY);
	g_ConVar_ReplayIdleAnytime 	= 		CreateConVar("sm_replay_idle_anytime", "0", "Allow idle even if no human players in game(via PCI).", FCVAR_NONE);
	g_hOnPlayTick 				= 		CreateGlobalForward("OnPlayTick", ET_Ignore, Param_Cell, Param_Cell);
	g_hOnRecordTick 			= 		CreateGlobalForward("OnRecordTick", ET_Ignore, Param_Cell, Param_Cell);
	g_ConVar_PosMap_x 			= 		CreateConVar("str_posmap_x", "0.0", "坐标映射x分量.", FCVAR_NOTIFY);
	g_ConVar_PosMap_y 			= 		CreateConVar("str_posmap_y", "0.0", "坐标映射y分量.", FCVAR_NOTIFY);
	g_ConVar_PosMap_z 			= 		CreateConVar("str_posmap_z", "0.0", "坐标映射z分量.", FCVAR_NOTIFY);
	
	HookEvent("player_disconnect", OnPlayerDisconnect, EventHookMode_Pre);
	HookEvent("map_transition", OnGameEvent);	
	HookEvent("player_bot_replace", Event_PlayerBotReplace);
	HookEvent("bot_player_replace", Event_PlayerBotReplace);
	HookEvent("player_use", Event_PlayerUse);
	
	decl String:sFilePath[64];
	BuildPath(Path_SM, sFilePath, sizeof(sFilePath), "gamedata/st_signs.txt");
	if (FileExists(sFilePath))
	{
		new Handle:hConfig = LoadGameConfigFile("st_signs");
		StartPrepSDKCall(SDKCall_Player);
		PrepSDKCall_SetFromConf(hConfig, SDKConf_Signature, "TakeOverBot");
		g_hTakeOverBot = EndPrepSDKCall();
		StartPrepSDKCall(SDKCall_Player);
		PrepSDKCall_SetFromConf(hConfig, SDKConf_Signature, "GoAwayFromKeyboard");
		g_hGoAwayFromKeyboard = EndPrepSDKCall();
		CloseHandle(hConfig);
	}
	
	
	Handle gameconfig = LoadGameConfigFile("funcommands.games");
	if (!gameconfig)
	{
		SetFailState("funcommands.games.txt not found.");
		return;
	}
	/*
	char spritebeam[PLATFORM_MAX_PATH];
	if (!GameConfGetKeyValue(gameconfig, "SpriteBeam", spritebeam, sizeof(spritebeam)) || !spritebeam[0])
	{
		SetFailState("SpriteBeam key value not found.");
		return;
	}

	STR_LaserSprite = PrecacheModel(spritebeam, true);
	*/
	
}




public void OnMapStart()
{
	for (new i = 1; i < MAXCLIENTS + 1; i++)
	{
		IsLinear_Transition[i] = false;
		g_bIsFileLoad[i] = false;
		PauseWhilePlaying[i] = false;
		i_linesmooth[i] = 0;
		Trace_Line[i] = 0;
		i_angsmooth[i] = 0;	
		IdleFlags[i] = 0;
		Isattack[i] = 0;
		ibuttonsEx[i] = 0;
		
		
	}	
	

}


public void ResetPlayerReplaySegment(int client)
{
	if (client < 1) return;
	if (!IsClientInGame(client)) return;
	
	Player_SetIsSegmenting(client, false);
	Player_SetIsRewinding(client, false);
	Player_SetHasRun(client, false);
	Player_SetPlayingReplay(client, false);
	
	if (IsPlayingOnTeam(client))
	{
		SetEntityMoveType(client, MOVETYPE_WALK);	
	}
	
	Player_SetRewindFrame(client, 0);
	Player_DeleteRecordFrames(client);
	RequestFrame(ResetButton, client);
	
	
}


public int MenuHandler_ReplaySelect(Menu menu, MenuAction action, int param1, int param2)
{
	int client = param1;

	if (action == MenuAction_Select)
	{
		
		char info[512];
		bool found = GetMenuItem(menu, param2, info, sizeof(info));
		
		if (!found)
		{
			return;
		}
		
		char mapbuf[MAX_NAME_LENGTH];
		GetCurrentMap(mapbuf, sizeof(mapbuf));
		
		char filepath[PLATFORM_MAX_PATH];
		BuildPath(Path_SM, filepath, sizeof(filepath), "%s/%s/%s/%s", STR_RootPath, STR_ReplayFolder, mapbuf, info);
		
		File file = OpenFile(filepath, "rb");
		
		if (file == null)
		{
			STR_PrintMessageToClient(client, "\"%s\" 无法打开", info);
			return;
		}
		
		//ResetPlayerReplaySegment(client);
		
		int framecount;		
		ReadFileCell(file, framecount, 4);
		
		
		Player_CreateFrameArray(client);		
		any frameinfo[FRAME_Length];			
		for (int i = 0; i < framecount; ++i)
		{			
			ReadFile(file, frameinfo, sizeof(frameinfo), 4);
			
			Player_PushFrame(client, frameinfo);
		}
		
		delete file;
		
		if(Player_GetStopFrame(client) == 0) 
		{
			Player_SetStopFrame(client, 99999);
			STR_PrintMessageToClient(client, "%N的StopFrame参数已自动设置为99999", client);
		}
		
		STR_PrintMessageToClient(client, "已加载Replay \"%s\"", info);
		g_bIsFileLoad[client] = true;		
		Player_SetHasRun(client, true);	
		
		
		STR_OpenSegmentReplayMenu(client);
		
	}
	
	else if (action == MenuAction_Cancel)
	{
		//to do later
	}
	
	else if (action == MenuAction_End)
	{		
		delete menu;
	}
}


public int MenuHandler_SegmentReplay(Menu menu, MenuAction action, int param1, int param2)
{
	int client = param1;
	
	if (action == MenuAction_Select)
	{
		char info[3];
		bool found = GetMenuItem(menu, param2, info, sizeof(info));
		
		if (!found)
		{
			return;
		}

		int itemid = StringToInt(info);
		
		switch (itemid)
		{
			case SEG_Start:
			{
				//PrintToChat(client, "%s", SEG_Start);			
				STR_PrintMessageToClient(client, "开始记录Rplay...");
				
				Player_SetIsSegmenting(client, true);
				Player_SetIsRewinding(client, false);
				Player_SetHasRun(client, false);
				Player_SetPlayingReplay(client, false);
				
				Player_CreateFrameArray(client);
				Player_SetRewindFrame(client, 0);
				
				
				STR_OpenSegmentReplayMenu(client);
				
			}
			
			case SEG_LoadFromFile:
			{
				//PrintToChat(client, "%s", SEG_LoadFromFile);			
				char mapbuf[MAX_NAME_LENGTH];
				GetCurrentMap(mapbuf, sizeof(mapbuf));
				
				char mapreplaybuf[PLATFORM_MAX_PATH];
				BuildPath(Path_SM, mapreplaybuf, sizeof(mapreplaybuf), "%s/%s/%s", STR_RootPath, STR_ReplayFolder, mapbuf);				
				if (!DirExists(mapreplaybuf))
				{
					STR_PrintMessageToClient(client, "无可用文件(\"%s\")", mapbuf);
					return;
				}
				
				DirectoryListing dirlist = OpenDirectory(mapreplaybuf);
				
				if (dirlist == null)
				{
					STR_PrintMessageToClient(client, "无法打开文件夹");
					return;
				}
				
				FileType curtype;
				char curname[512];
				int index = 0;
				
				Menu selectmenu = CreateMenu(MenuHandler_ReplaySelect);
				SetMenuTitle(selectmenu, "选择Replay文件");
				
				while (dirlist.GetNext(curname, sizeof(curname), curtype))
				{
					if (curtype != FileType_File)
						continue;

					AddMenuItem(selectmenu, curname, curname);
					index++;
				}

				delete dirlist;

				if (index == 0)
				{
					STR_PrintMessageToClient(client, "No replays available");
					return;
				}
				
				DisplayMenu(selectmenu, client, MENU_TIME_FOREVER);
			}
			
			case MOV_Blank:
			{
				
			}
			
			case MOV_SaveToFile:
			{
				//PrintToChat(client, "%s", MOV_SaveToFile);			
				char mapbuf[MAX_NAME_LENGTH];
				GetCurrentMap(mapbuf, sizeof(mapbuf));
				
				char playernamebuf[MAX_NAME_LENGTH];
				GetClientName(client, playernamebuf, sizeof(playernamebuf));
				
				char newdirbuf[PLATFORM_MAX_PATH];
				BuildPath(Path_SM, newdirbuf, sizeof(newdirbuf), "%s/%s/%s", STR_RootPath, STR_ReplayFolder, mapbuf);
				
				if (!DirExists(newdirbuf))
					CreateDirectory(newdirbuf, 511);
				
				//int steamid = GetSteamAccountID(client);
				
				char timebuf[128];
				FormatTime(timebuf, sizeof(timebuf), "%Y %m %d, %H %M %S");
				
				char namebuf[256];
				//FormatEx(namebuf, sizeof(namebuf), "[%d] %s (%s)", steamid, playernamebuf, timebuf);
				//FormatEx(namebuf, sizeof(namebuf), "[%s] %s (%s)", mapbuf, playernamebuf, timebuf);
				FormatEx(namebuf, sizeof(namebuf), "[%s] (%s)", mapbuf, timebuf);//去掉玩家名字，防止无法保存replay
				
				char filename[PLATFORM_MAX_PATH];
				FormatEx(filename, sizeof(filename), "%s/%s.STR", newdirbuf, namebuf);
				
				File file = OpenFile(filename, "wb");
				
				if (file == null)
				{
					STR_PrintMessageToClient(client, "无法保存Replay");
					return;
				}
				
				int framecount = Player_GetRecordedFramesCount(client);
				WriteFileCell(file, framecount, 4);
				
				any frameinfo[FRAME_Length];
				
				for (int i = 0; i < framecount; ++i)
				{
					Player_GetFrame(client, i, frameinfo);
					
					for (int j = 0; j < FRAME_Length; ++j)
					{
						WriteFileCell(file, frameinfo[j], 4);
					}
				}
				
				delete file;
				STR_PrintMessageToClient(client, "保存Replay文件： \"%s\"", namebuf);
				
				
				if(GetConVarBool(b_ReplayDebug))
				{
					//========================================================================
					char filename_rec_x[PLATFORM_MAX_PATH];
					FormatEx(filename_rec_x, sizeof(filename_rec_x), "%s/Pos_x.txt", newdirbuf);
					
					File file_rec_x = OpenFile(filename_rec_x, "w");
					if (file_rec_x == null)
					{
						STR_PrintMessageToClient(client, "无法保存Replay");
						return;
					}
					
					for (int i = 0; i < framecount; ++i)
					{
						Player_GetFrame(client, i, frameinfo);						
						for (int j = 0; j < FRAME_Length; ++j)
						{
							
							WriteFileLine(file_rec_x, "%.03f", frameinfo[FRAME_PosX]);
						}
					}
					delete file_rec_x;
					STR_PrintMessageToClient(client, "保存文件： \"%s\"", namebuf);
					//========================================================================
					
					
					
					
					//========================================================================
					char filename_rec_y[PLATFORM_MAX_PATH];
					FormatEx(filename_rec_y, sizeof(filename_rec_y), "%s/Pos_y.txt", newdirbuf);
					
					File file_rec_y = OpenFile(filename_rec_y, "w");
					if (file_rec_y == null)
					{
						STR_PrintMessageToClient(client, "无法保存Replay");
						return;
					}
					
					for (int i = 0; i < framecount; ++i)
					{
						Player_GetFrame(client, i, frameinfo);
						
						for (int j = 0; j < FRAME_Length; ++j)
						{
							
							WriteFileLine(file_rec_y, "%.03f", frameinfo[FRAME_PosY]);
						}
					}
					delete file_rec_y;
					STR_PrintMessageToClient(client, "保存文件： \"%s\"", namebuf);
					//========================================================================
					
					
					
					
					//========================================================================
					char filename_rec_z[PLATFORM_MAX_PATH];
					FormatEx(filename_rec_z, sizeof(filename_rec_z), "%s/Pos_z.txt", newdirbuf);
					
					File file_rec_z = OpenFile(filename_rec_z, "w");
					if (file_rec_z == null)
					{
						STR_PrintMessageToClient(client, "无法保存Replay");
						return;
					}
					
					for (int i = 0; i < framecount; ++i)
					{
						Player_GetFrame(client, i, frameinfo);
						
						for (int j = 0; j < FRAME_Length; ++j)
						{
							
							WriteFileLine(file_rec_z, "%.03f", frameinfo[FRAME_PosZ]);
						}
					}
					delete file_rec_z;
					STR_PrintMessageToClient(client, "保存文件： \"%s\"", namebuf);
					//========================================================================
					
				}	

				STR_OpenSegmentReplayMenu(client);
			}
			
			case SEG_Resume:
			{
				float t_scale = GetConVarFloat(FindConVar("host_timescale"));
				CreateTimer(2*t_scale, Resume_record_play, client, TIMER_REPEAT);
				
			}
			case SEG_Resume_Now:
			{
				Player_SetIsRewinding(client, false);
				SetEntityMoveType(client, MOVETYPE_WALK);		
				Player_SetLastPausedTick(client, Player_GetRewindFrame(client));			
				Player_ResizeRecordFrameList(client, Player_GetRewindFrame(client));
				STR_OpenSegmentReplayMenu(client);	
				
			}
			
			case SEG_EXIT:
			{
				ResetPlayerReplaySegment(client);
				RequestFrame(ResetButton, client);
			}
			
			case SEG_Pause:
			{
				//PrintToChat(client, "%s", SEG_Pause);				
				Player_SetIsRewinding(client, true);
				Player_SetIsSegmenting(client, true);
				Player_SetHasRun(client, false);
				Player_SetPlayingReplay(client, false);
				
				SetEntityMoveType(client, MOVETYPE_NONE);				
				//Player_SetRewindFrame(client, Player_GetRecordedFramesCount(client) - 1);
				
				
				STR_OpenSegmentReplayMenu(client);
			}
			
			case SEG_GoBack:
			{
				//PrintToChat(client, "%s", SEG_GoBack);				
				int newframe = Player_GetLastPausedTick(client);				
				newframe = Player_ClampRecordFrame(client, newframe);				
				Player_SetRewindFrame(client, newframe);				
				Player_SetIsRewinding(client, true);				
				SetEntityMoveType(client, MOVETYPE_NONE);
				
				
				
				STR_OpenSegmentReplayMenu(client);
			}
			
			case SEG_Play:
			{
				//PrintToChat(client, "%s", SEG_Play);				
				Player_SetPlayingReplay(client, true);
				Player_SetRewindFrame(client, 0);
				Player_SetIsRewinding(client, true);	
				STR_PrintMessageToClient(client, "开始播放Replay.");
				
				
				STR_OpenSegmentReplayMenu(client);		
				
			}
			
			case SEG_Play_Trace:
			{
				
				decl String:tracebuf[128];
				Format(tracebuf, sizeof(tracebuf), "sm_replaydrawtrace %d", client);
				ClientCommand(client, tracebuf);	
				STR_OpenSegmentReplayMenu(client);		
				
			}
			case SEG_Play_Trace_PosMap:
			{
				
				decl String:tracebuf[128];
				Format(tracebuf, sizeof(tracebuf), "sm_replaydrawtrace_posmap %d", client);
				ClientCommand(client, tracebuf);	
				STR_OpenSegmentReplayMenu(client);		
				
			}
			
			case SEG_Play_Trace_Close:
			{
				decl String:traceclosebuf[128];
				Format(traceclosebuf, sizeof(traceclosebuf), "sm_replaydrawtraceclose %d", client);
				ClientCommand(client, traceclosebuf);	
				STR_OpenSegmentReplayMenu(client);	
				
				
			}
			
			case SEG_Stop:
			{
				//PrintToChat(client, "%s", SEG_Stop);				
				Player_SetHasRun(client, true);
				Player_SetIsSegmenting(client, false);
				Player_SetIsRewinding(client, false);
				Player_SetPlayingReplay(client, false);				
				SetEntityMoveType(client, MOVETYPE_WALK);	
				
				
				
				STR_OpenSegmentReplayMenu(client);		
				
			}
			
			
			case Step_Back:
			{
				STR_StepBack(client, Player_GetRewindSpeed(client));
				STR_OpenSegmentReplayMenu(client);	
				
			}
			
			case Step_Forward:
			{
				STR_StepForward(client, Player_GetRewindSpeed(client));
				STR_OpenSegmentReplayMenu(client);
				
			}
			
			case Rewind:
			{
				STR_RewindDown(client, 1);
				STR_OpenSegmentReplayMenu(client);	
			}
			
			case Fastforward:
			{
				STR_FastForwardDown(client, 1);
				STR_OpenSegmentReplayMenu(client);	
			}
			
			
			case MOV_Resume:
			{
				//PrintToChat(client, "%s", MOV_Resume);			
				Player_SetIsRewinding(client, false);				
				SetEntityMoveType(client, MOVETYPE_WALK);	
				//f_host_timescale = GetConVarFloat(FindConVar("host_timescale"));
				STR_OpenSegmentReplayMenu(client);
			}
			
			case MOV_Resume_Close:
			{
				CreateTimer(1.5, Resume_play_close, client, TIMER_REPEAT);				
				
			}
			
			case MOV_NewFrom:
			{
				//PrintToChat(client, "%s", MOV_NewFrom);
				/*
					This reuses the active frame's data as the start for the new run
				*/
				
				any frameinfo[FRAME_Length];
				
				int frame = Player_GetRewindFrame(client);
				Player_GetFrame(client, frame, frameinfo);				
				ResetPlayerReplaySegment(client);
				Player_SetIsSegmenting(client, true);
				Player_SetIsRewinding(client, true);
				Player_SetHasRun(client, true);
				Player_SetPlayingReplay(client, true);				
				Player_CreateFrameArray(client);
				Player_SetRewindFrame(client, 0);				
				Player_PushFrame(client, frameinfo);
				
				/*
					Forcing a teamchange like this does open the "select character" menu but does not
					kill the player upon choosing
				*/
				
				SetEntityMoveType(client, MOVETYPE_NONE);	
				
				
				STR_OpenSegmentReplayMenu(client);			
			}
			
			case MOV_Stop:
			{
				//PrintToChat(client, "%s", MOV_Stop);
				Player_SetHasRun(client, true);
				Player_SetIsSegmenting(client, false);
				Player_SetIsRewinding(client, false);
				Player_SetPlayingReplay(client, false);
				STR_OpenSegmentReplayMenu(client);				
			}
			
			case MOV_Pause:
			{
				//PrintToChat(client, "%s", MOV_Pause);				
				Player_SetIsRewinding(client, true);				
				STR_OpenSegmentReplayMenu(client);				
			}
			
			case MOV_Replay2Record:
			{
				//从播放直接转为录制状态
				//PrintToChat(client, "%s", MOV_ContinueFrom);				
				//PrintToChat(client, "0: %d %d", RecordFramesList[client].Length, CurrentRewindFrame[client]);				
				int endframe = Player_GetRewindFrame(client) + 1;
				int framecount = Player_GetRecordedFramesCount(client) - 1;				
				if (endframe > framecount)
				{
					endframe = framecount;
				}
				
				/*
					Truncate anything past this point if we are not at the end
				*/
				Player_ResizeRecordFrameList(client, endframe);	
				
				
				Player_SetIsSegmenting(client, true);
				Player_SetIsRewinding(client, false);
				Player_SetHasRun(client, false);
				Player_SetPlayingReplay(client, false);
				
				SetEntityMoveType(client, MOVETYPE_WALK);
				Player_SetRewindFrame(client, endframe - 1);
				
				RequestFrame(ResetButton, client);
				//PrintToChat(client, "1: %d %d", RecordFramesList[client].Length, CurrentRewindFrame[client]);	
				
				STR_OpenSegmentReplayMenu(client);				
			}
			
			case MOV_ContinueFrom:
			{
				//PrintToChat(client, "%s", MOV_ContinueFrom);				
				//PrintToChat(client, "0: %d %d", RecordFramesList[client].Length, CurrentRewindFrame[client]);				
				int endframe = Player_GetRewindFrame(client) + 1;
				int framecount = Player_GetRecordedFramesCount(client) - 1;				
				if (endframe > framecount)
				{
					endframe = framecount;
				}
				
				/*
					Truncate anything past this point if we are not at the end
				*/
				Player_ResizeRecordFrameList(client, endframe);				
				Player_SetIsSegmenting(client, true);
				Player_SetIsRewinding(client, true);
				Player_SetHasRun(client, false);
				Player_SetPlayingReplay(client, false);
				SetEntityMoveType(client, MOVETYPE_NONE);
				Player_SetRewindFrame(client, endframe - 1);
				RequestFrame(ResetButton, client);
				//PrintToChat(client, "1: %d %d", RecordFramesList[client].Length, CurrentRewindFrame[client]);	
				
				STR_OpenSegmentReplayMenu(client);				
			}
			case RewindSpeed_All:
			{
				//PrintToChat(client, "%s", RewindSpeed_All);				
				int curspeed = Player_GetRewindSpeed(client);
				
				curspeed *= 4;				
				if (curspeed > 64)
				{
					curspeed = 1;
				}
				
				Player_SetRewindSpeed(client, curspeed);
				STR_OpenSegmentReplayMenu(client);				
			}
			
			case JumpToStart:
			{
				//PrintToChat(client, "%s", JumpToStart);			
				Player_SetRewindFrame(client, 0);	
				STR_OpenSegmentReplayMenu(client);
			}
			
			case JumpToEnd:
			{
				//PrintToChat(client, "%s", JumpToEnd);				
				Player_SetRewindFrame(client, Player_GetRecordedFramesCount(client) - 1);
				STR_OpenSegmentReplayMenu(client);				
			}
		}
	}
	
	else if (action == MenuAction_Cancel)
	{
		//KillTimer(Timer_Draw_Trace[client]);
		ResetPlayerReplaySegment(client);
		g_bIsFileLoad[client] = false;
		ClientCommand(client, "-duck");
		ClientCommand(client, "-forward");
		ClientCommand(client, "-back");
		ClientCommand(client, "-attack");
		ClientCommand(client, "-use");
		//STR_PrintMessageToClient(client, "MenuAction_Cancel.");
	}
	
	else if(action == MenuAction_End)
	{
		//STR_PrintMessageToClient(client, "MenuAction_End");
		//STR_OpenSegmentReplayMenu(client);
		delete menu;
	}
}

public bool IsPlayingOnTeam(int client)   //判断是否是生还者或感染者
{
	int team = GetClientTeam(client);
	
	return team != L4D2_TEAM_SPECTATOR && team != L4D2_TEAM_NONE && IsPlayerAlive(client);
}

public void STR_OpenSegmentReplayMenu(int client)
{
	
	bool onteam = IsPlayingOnTeam(client);				
	Menu menu = CreateMenu(MenuHandler_SegmentReplay);	
	//Player_PrintInfo(client);	
	SetMenuTitle(menu, "Speedrun TAS Tools (By 悠夏line)");
	if (!Player_GetIsSegmenting(client))
	{
		if (!Player_GetHasRun(client))
		{
			if (onteam)
			{
				Menu_AddEnumEntry(menu, SEG_Start, "开始Replay");
			}
			
			else
			{
				STR_PrintMessageToClient(client, "闲置期间无法录制Replay");
			}
			
			Menu_AddEnumEntry(menu, SEG_LoadFromFile, "加载Replay");
			
		}
		
		else
		{
			if (Player_GetIsPlayingReplay(client))
			{
				if (Player_GetIsRewinding(client))
				{
					
					Menu_AddEnumEntry(menu, MOV_Resume, "继续");
					//Menu_AddEnumEntry(menu, MOV_Resume_Close, "继续并关闭菜单");
					//char speedstr[64];
					//FormatEx(speedstr, sizeof(speedstr), "Speed: x%d", Player_GetRewindSpeed(client));
					Menu_AddEnumEntry(menu, JumpToStart, "跳转至开头");					
					Menu_AddEnumEntry(menu, JumpToEnd, "跳转至结尾");					
					Menu_AddEnumEntry(menu, MOV_ContinueFrom, "从此处继续Replay");
					Menu_AddEnumEntry(menu, MOV_NewFrom, "从此处开始新Replay");
					
				}
				
				else
				{
					Menu_AddEnumEntry(menu, MOV_Pause, "暂停");
					Menu_AddEnumEntry(menu, MOV_Replay2Record, "转为录制");
					
				}
				Menu_AddEnumEntry(menu, MOV_SaveToFile, "保存Replay");
				//Menu_AddEnumEntry(menu, MOV_Blank, " ");
				
			}
			
			else
			{
				Menu_AddEnumEntry(menu, SEG_Play, "播放Replay");			
				Menu_AddEnumEntry(menu, SEG_Play_Trace, "绘制Replay轨迹");			
				Menu_AddEnumEntry(menu, SEG_Play_Trace_PosMap, "绘制坐标映射轨迹(Def Trick.)");			
				Menu_AddEnumEntry(menu, SEG_Play_Trace_Close, "关闭绘制轨迹");			
				
			}
		}
	}
	
	else
	{
		if (Player_GetIsRewinding(client))
		{
			
			char speedstr[64];
			FormatEx(speedstr, sizeof(speedstr), "跳转帧数(x值): %d", Player_GetRewindSpeed(client));			
			Menu_AddEnumEntry(menu, SEG_Resume, "继续(两秒后)");
			Menu_AddEnumEntry(menu, Step_Forward, "前进x帧");
			Menu_AddEnumEntry(menu, Step_Back, "后退x帧");
			Menu_AddEnumEntry(menu, RewindSpeed_All, speedstr);
			Menu_AddEnumEntry(menu, MOV_SaveToFile, "保存Replay");
			//Menu_AddEnumEntry(menu, Fastforward, "快进");			
			//Menu_AddEnumEntry(menu, Rewind, "快退");
			Menu_AddEnumEntry(menu, SEG_Resume_Now, "立即继续");
			//Menu_AddEnumEntry(menu, JumpToStart, "跳转至开头");
			//Menu_AddEnumEntry(menu, JumpToEnd, "跳转至结尾");
			//Menu_AddEnumEntry(menu, SEG_Stop, "跳转至上一个存档点");			
			//Menu_AddEnumEntry(menu, SEG_Stop, "停止&播放Replay");			
			
			//Menu_AddEnumEntry(menu, Step_Back, "Step Back");
			//Menu_AddEnumEntry(menu, Step_Forward, "Step Forward");
			//Menu_AddEnumEntry(menu, Rewind, "Rewind");
			//Menu_AddEnumEntry(menu, Fastforward, "Fastforward");
			
		}
		
		else
		{
			Menu_AddEnumEntry(menu, SEG_Pause, "暂停");
		}
	}
	Menu_AddEnumEntry(menu, SEG_EXIT, "退出菜单");
	DisplayMenu(menu, client, MENU_TIME_FOREVER);

	
}

public Action:STR_ManageReplays(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[STR] - This command can only be used in-game.");
		return Plugin_Handled;
	}
	STR_OpenSegmentReplayMenu(client);
	return Plugin_Handled;
}

/*
	Step forward a single tick
*/
public Action STR_StepForward(int client, int args)
{
	if (!Player_GetIsRewinding(client))
	{ 
		return Plugin_Handled;
	}
	
	int oldfactor = Player_GetRewindSpeed(client);
	Player_SetRewindSpeed(client, args);
	Player_SetHasFastForwardKeyDown(client, true);
	HandleReplayRewind(client);
	Player_SetRewindSpeed(client, oldfactor);
	Player_SetHasFastForwardKeyDown(client, false);
	
	return Plugin_Handled;
}

/*
	Step back a single tick
*/
public Action STR_StepBack(int client, int args)
{
	if (!Player_GetIsRewinding(client))
	{ 
		return Plugin_Handled;
	}
	
	int oldfactor = Player_GetRewindSpeed(client);
	
	Player_SetRewindSpeed(client, args);
	Player_SetHasRewindKeyDown(client, true);
	HandleReplayRewind(client);
	Player_SetRewindSpeed(client, oldfactor);
	Player_SetHasRewindKeyDown(client, false);
	return Plugin_Handled;
}

/*
	==============================================================
*/

public Action STR_RewindDown(int client, int args)
{
	if (!Player_GetIsRewinding(client))
	{  
		return Plugin_Handled;
	}
	Player_SetHasRewindKeyDown(client, true);
	return Plugin_Handled;
}



public Action STR_RewindUp(int client, int args)
{
	if (!Player_GetIsRewinding(client))
	{ 
		return Plugin_Handled;
	}
	Player_SetHasRewindKeyDown(client, false);
	return Plugin_Handled;
}



/*
	==============================================================
*/

public Action STR_FastForwardDown(int client, int args)
{
	if (!Player_GetIsRewinding(client))
	{ 
		return Plugin_Handled;
	}
	Player_SetHasFastForwardKeyDown(client, true);
	return Plugin_Handled;
}


public Action OnPlayerDisconnect(Event event, const char[] name, bool dontbroadcast)
{
	int userid = GetEventInt(event, "userid");
	int client = GetClientOfUserId(userid);	
	if (client < 1) return;
	ResetPlayerReplaySegment(client);
}

public Action OnPlayerWeaponDrop(Event event, const char[] name, bool dontbroadcast)
{
	int userid = GetEventInt(event, "userid");
	int client = GetClientOfUserId(userid);	
	int entindex = GetEventInt(event, "propid");
	AcceptEntityInput(entindex, "Kill");
	STR_PrintMessageToAllClients("%N 扔出的东西已移除", client);
}

public Action OnPlayeItemPickup(Event event, const char[] name, bool dontbroadcast)
{
	int userid = GetEventInt(event, "userid");
	int client = GetClientOfUserId(userid);	
	int weapon = GetPlayerWeaponSlot(client, 4);
	AcceptEntityInput(weapon, "Kill");
	STR_PrintMessageToAllClients("%N 捡起的东西已移除", client);
}

public Action OnPlayeWeaponGiven(Event event, const char[] name, bool dontbroadcast)
{
	int userid = GetEventInt(event, "userid");
	int giver = GetEventInt(event, "giver");
	int client = GetClientOfUserId(userid);	
	int client_giver = GetClientOfUserId(giver);	
	int weapon = GetEventInt(event, "weaponentid");
	AcceptEntityInput(weapon, "Kill");
	STR_PrintMessageToAllClients("Client: %N ", client);
	STR_PrintMessageToAllClients("Giver: %N ", client_giver);
	
}

public void SetPlayerReplayFrame(int client, int targetclient, int frame)
{
	any frameinfo[FRAME_Length];
	Player_GetFrame(client, frame, frameinfo);
	
	float pos[3];
	float frameangles[2];
	float velocity[3];
	GetArrayVector3(frameinfo, FRAME_PosX, pos);
	GetArrayVector2(frameinfo, FRAME_AngX, frameangles);	
	GetArrayVector3(frameinfo, FRAME_VelX, velocity);
	
	float viewangles[3];
	CopyVector2ToVector3(frameangles, viewangles);
	TeleportEntity(targetclient, pos, viewangles, velocity);
}

public void HandleReplayRewind(int client)
{
	int lastindex = Player_GetRecordedFramesCount(client) - 1;
	int factor = Player_GetRewindSpeed(client);
	int curframe = Player_GetRewindFrame(client);
	
	/*
		Rewind
	*/
	if (Player_GetHasRewindKeyDown(client))
	{
		Player_SetRewindFrame(client, curframe - factor);
	}
	
	/*
		Fast forard
	*/
	if (Player_GetHasFastForwardKeyDown(client))
	{
		Player_SetRewindFrame(client, curframe + factor);
	}
	
	curframe = Player_GetRewindFrame(client);
	if (curframe < 0)
	{
		Player_SetRewindFrame(client, 0);
	}
	else if (curframe > lastindex)
	{
		Player_SetRewindFrame(client, lastindex);
	}
	
	curframe = Player_GetRewindFrame(client);
	/*
		Should display this in a center bottom panel thing instead
	*/
	if (lastindex > 0)
	{
		float tickinterval = GetTickInterval();		
		int timeframe = Player_GetRewindFrame(client) - Player_GetStartTimeReplayTick(client);
		
		if (timeframe < 0)
		{
			timeframe = 0;
		}
		
		float curtime = timeframe * tickinterval;		
		char curtimebuf[64];
		FormatTimeSpan(curtimebuf, sizeof(curtimebuf), curtime);
		if(GetConVarBool(b_ShowFrame))
		{
			PrintCenterText(client, "%d / %d\nTime: %s", curframe, lastindex, curtimebuf);
		}

		
		
	}
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float wishvel[3], float wishangles[3], int& weapon)
{
	Action ret = Plugin_Continue;	
	
	
	if (Player_GetIsSegmenting(client))
	{
		if (Player_GetIsRewinding(client))
		{
			HandleReplayRewind(client);
			SetPlayerReplayFrame(client, client, Player_GetRewindFrame(client));
			ret = Plugin_Handled;
		}
		/*
			Recording
		*/
		else
		{
			//STR_PrintMessageToClient(client, "Recording_Test.");
			float pos[3];
			GetClientAbsOrigin(client, pos);
			
			float viewangles[3];
			GetClientEyeAngles(client, viewangles);
			
			float frameangles[2];
			CopyVector3ToVector2(viewangles, frameangles);
			
			float velocity[3];
			GetEntPropVector(client, Prop_Data, "m_vecVelocity", velocity);
			any frameinfo[FRAME_Length];
			frameinfo[FRAME_Buttons] = buttons | IdleFlags[client];
			frameinfo[FRAME_FFLAG] = GetEntityFlags(client);
			frameinfo[FRAME_MOVETYPE] = GetEntityMoveType(client);
			frameinfo[FRAME_ACTIVESLOT] = GetActiveSlot(client);	//暂时只是记录，没有用处
			
			CopyVector3ToArray(pos, frameinfo, FRAME_PosX);
			CopyVector2ToArray(frameangles, frameinfo, FRAME_AngX);
			CopyVector3ToArray(velocity, frameinfo, FRAME_VelX);
			
			if (IdleFlags[client] > 0) IdleFlags[client] = 0;
			int item;
			if (weapon > 0)
			{
				decl String:sClass[64];
				GetEntityClassname(weapon, sClass, sizeof(sClass));
				for (new i = 1; i < ITEMS_COUNT; i++)
				{
					if (StrEqual(sClass, g_Items[i]))
					{
						item = i;
						break;
					}
				}
			}
			frameinfo[FRAME_WEAPON] = item;	
			Player_PushFrame(client, frameinfo);

			int curframe = Player_GetRewindFrame(client);
			//代码实现来自PCI:Movement Reader
			Call_StartForward(g_hOnRecordTick);
			Call_PushCell(client);
			Call_PushCell(curframe);
			Call_Finish();
			decl String:sKeyValue[128];
			Format(sKeyValue, sizeof(sKeyValue), "if (\"OnRecordTick\" in getroottable()) OnRecordTick(self, %d)", curframe);
			SetVariantString(sKeyValue);
			AcceptEntityInput(client, "RunScriptCode");

			Player_SetRewindFrame(client, Player_GetRecordedFramesCount(client) - 1);	
			//PrintToServer("Client: %d Frame: %d", client, RecordFramesList[client].Length);	
			
			
			ret = Plugin_Changed;
		}
	}
	
	/*
		Rewinding while recording
	*/
	else if (Player_GetIsPlayingReplay(client) && Player_GetIsRewinding(client))
	{
		HandleReplayRewind(client);
		SetPlayerReplayFrame(client, client, Player_GetRewindFrame(client));		
		ret = Plugin_Handled;
	}
	
	/*
		Playing
	*/
	if(!GetConVarBool(b_PlayWhenIncapacitated)) {	// 20230108: 倒地是否继续播放replay
		if(GetEntProp(client, Prop_Send, "m_isIncapacitated") != 0) return Plugin_Continue;
	}
	//if(GetClientTeam(client) == 2)						//判断玩家是否在生还者阵营，如果闲置就会导致replay停止播放，因此不要加这个判断。
	if(PauseWhilePlaying[client])							//暂停replay
	{
		TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, {0, 0, 0});//有warning
		return Plugin_Continue;
	}
	else
	{		
		bool normalproc = true;
		if (Player_GetIsPlayingReplay(client))
		{
			int curframe = Player_GetRewindFrame(client);
			any frameinfo[FRAME_Length];
			Player_GetFrame(client, curframe, frameinfo);
			any frameinfo_action[FRAME_Length];					//frameinfo_action是为了解决动作比位置信息滞后1tick的问题，因此取curframe后面一帧的信息
			Player_GetFrame(client, curframe + 1, frameinfo_action);
			
			float pos[3];
			float frameangles[2];
			float velocity[3];
			
			GetArrayVector3(frameinfo, FRAME_PosX, pos);
			GetArrayVector2(frameinfo, FRAME_AngX, frameangles);			
			GetArrayVector3(frameinfo, FRAME_VelX, velocity);
			
			float viewangles[3];
			GetArrayVector2(frameinfo, FRAME_AngX, frameangles);		
			CopyVector2ToVector3(frameangles, viewangles);

			
			if(Player_GetStopFrame(client) && !IsFakeClient(client))
			{
				if(curframe == Player_GetStopFrame(client) && GetConVarBool(b_PlayingToRecord))
				{
					
					normalproc = false;				
					HandleReplayRewind(client);				
					TeleportEntity(client, NULL_VECTOR, viewangles, velocity);
					DispatchKeyValueVector(client, "origin", pos);
					
					int endframe = Player_GetRewindFrame(client) + 1;
					int framecount = Player_GetRecordedFramesCount(client) - 1;				
					if (endframe > framecount)
					{
						endframe = framecount;
					}
					//Truncate anything past this point if we are not at the end
					
					Player_ResizeRecordFrameList(client, endframe);	
					Player_SetIsRewinding(client, true);
					Player_SetIsSegmenting(client, true);
					Player_SetHasRun(client, false);
					Player_SetPlayingReplay(client, false);
					SetEntityMoveType(client, MOVETYPE_NONE);
					Player_SetRewindFrame(client, endframe - 1);
					//STR_OpenSegmentReplayMenu(client);  //不能直接打开菜单,有BUG
					
					ClientCommand(client, "slot1");
					ClientCommand(client, "-duck");
					//SetConVarFloat(FindConVar("host_timescale"), 0.03, true, true);
					STR_PrintMessageToAllClients("%N的Replay已经从%d帧继续.", client, endframe);
					
				}
				else if(curframe == Player_GetStopFrame(client))
				{
					ResetPlayerReplaySegment(client);
					STR_PrintMessageToAllClients("%N的Replay在%d帧停止.", client, curframe);
				}
			}
			
			/*
				Paused while watching a replay, this will allow the player
				to edit a bot while it's playing
			*/
			if (Player_GetIsRewinding(client))
			{
				normalproc = false;				
				HandleReplayRewind(client);				
				//TeleportEntity(client, pos, viewangles, velocity);				
				TeleportEntity(client, NULL_VECTOR, viewangles, velocity);
				DispatchKeyValueVector(client, "origin", pos);
			}
			
			{
				
				if (frameinfo[FRAME_WEAPON] > 0) FakeClientCommand(client, "use %s", g_Items[frameinfo[FRAME_WEAPON]]);
				
				//Buttons=================================================================================================
				ibuttons[client] = frameinfo[FRAME_Buttons];
				if(!IsFakeClient(client) || (GetClientTeam(client) == 3)) //buttons = frameinfo[FRAME_Buttons];
				{
					if(ibuttons[client] & IN_JUMP) buttons |= IN_JUMP;
					else buttons &= ~IN_JUMP;
				
					if(ibuttons[client] & IN_DUCK) ClientCommand(client, "+duck");
					else ClientCommand(client, "-duck");
					
					if(ibuttons[client] & IN_FORWARD && GetEntityFlags(client) & FL_ONGROUND) ClientCommand(client, "+forward");
					else ClientCommand(client, "-forward");
					
					if(ibuttons[client] & IN_BACK && GetEntityFlags(client) & FL_ONGROUND) ClientCommand(client, "+back");
					else ClientCommand(client, "-back");
					
					if(ibuttons[client] & IN_LEFT) ClientCommand(client, "+left");
					else ClientCommand(client, "-left");
					
					if(ibuttons[client] & IN_RIGHT) ClientCommand(client, "+right");
					else ClientCommand(client, "-right");
					
					if(ibuttons[client] & IN_ATTACK2) ClientCommand(client, "+attack2");
					else ClientCommand(client, "-attack2");
					
					if(ibuttons[client] & IN_RELOAD) ClientCommand(client, "+reload");
					else ClientCommand(client, "-reload");
					
				
				}	
				ibuttonsEx[client] = frameinfo_action[FRAME_Buttons];
				//if (ibuttonsEx[client] & IN_IDLE) ST_Idle(client);//插件自动闲置
				//if (ibuttonsEx[client] & IN_TAKEOVER) ST_Idle(client, true);//插件自动闲置
				
				if(ibuttonsEx[client] & IN_USE) ClientCommand(client, "+use");
				else ClientCommand(client, "-use");
				
				if(ibuttonsEx[client] & IN_ATTACK) 
				{	
					ClientCommand(client, "+attack");
					Isattack[client] = 1;
				}
				else 
				{	
					Isattack[client]--;						
					if(!Isattack[client]) ClientCommand(client, "-attack");
					if(Isattack[client] < 0) Isattack[client] = 0;
				}
				//Buttons=================================================================================================
				if (curframe == 0)
				{
					TeleportEntity(client, NULL_VECTOR, viewangles, velocity);
					DispatchKeyValueVector(client, "origin", pos);
					f_host_timescale = GetConVarFloat(FindConVar("host_timescale"));
				}
				else
				{				
					//*
					if(IsLinear_Transition[client])
					{
						linetickcount[client] = Player_GetEndFrame(client) - Player_GetStartFrame(client);
						
						if(i_linesmooth[client] == linetickcount[client])
						{
							//STR_PrintMessageToClient(client, "线性平滑开始.");
							any frameinfo_linesmooth[FRAME_Length];
							GetClientAbsOrigin(client, pos_start[client]);
							GetClientEyeAngles(client, viewangles_start[client]);
							
							Player_GetFrame(client, Player_GetEndFrame(client), frameinfo_linesmooth);							
							GetArrayVector3(frameinfo_linesmooth, FRAME_PosX, pos_end[client]);
							GetArrayVector2(frameinfo_linesmooth, FRAME_AngX, frameangles_end[client]);							
							
						}
						if(i_linesmooth[client])
						{
							
							outpos[client][0] = LinearInterPolation_Pos(pos_start[client][0], pos_end[client][0], linetickcount[client] - i_linesmooth[client], linetickcount[client]);		
							outpos[client][1] = LinearInterPolation_Pos(pos_start[client][1], pos_end[client][1], linetickcount[client] - i_linesmooth[client], linetickcount[client]);	
							outpos[client][2] = LinearInterPolation_Pos(pos_start[client][2], pos_end[client][2], linetickcount[client] - i_linesmooth[client], linetickcount[client]);	
							
							outang[client][0] = LinearInterPolation(viewangles_start[client][0], frameangles_end[client][0], linetickcount[client] - i_linesmooth[client], linetickcount[client]);		
							outang[client][1] = LinearInterPolation(viewangles_start[client][1], frameangles_end[client][1], linetickcount[client] - i_linesmooth[client], linetickcount[client]);	
							CopyVector2ToVector3(outang[client], viewangles_line[client]);	
							
							//TeleportEntity(client, outpos[client], viewangles_line[client], velocity);
							TeleportEntity(client, NULL_VECTOR, viewangles_line[client], velocity);
							DispatchKeyValueVector(client, "origin", outpos[client]);
							i_linesmooth[client] --;
							//STR_PrintMessageToClient(client, "%d", i_linesmooth[client]);							
							//STR_PrintMessageToClient(client, "%f", outang[client][1]);
							
						}
						else
						{
							//TeleportEntity(client, pos, viewangles, velocity);
							TeleportEntity(client, NULL_VECTOR, viewangles, velocity);
							DispatchKeyValueVector(client, "origin", pos);							
							
						}
						if(!i_linesmooth[client])
						{
							IsLinear_Transition[client] = false;
							STR_PrintMessageToClient(client, "线性平滑结束");
						}
					
					}
					else
					//*/
					{	
						//Replay中自由视角的控制(此功能禁止开放给Bot)
						if(!IsFakeClient(client))
						{	
							//获取tickcount个tick以后数据
							int b_buttons = GetClientButtons(client);	
							if(b_buttons & IN_ZOOM)
							{							
								//TeleportEntity(client, pos, NULL_VECTOR, velocity);
								TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, velocity);
								DispatchKeyValueVector(client, "origin", pos);
								i_angsmooth[client] = tickcount;
								SetConVarFloat(FindConVar("host_timescale"), 0.08, true, true);
							}
							else 
							{
								
								if(i_angsmooth[client])
								{
									preframeang = Player_PreRewindFrame(client, tickcount);	
									any preframeinfoang[FRAME_Length];						
									Player_GetFrame(client, preframeang, preframeinfoang);
									GetArrayVector2(preframeinfoang, FRAME_AngX, preframeangles);	
									
									if(i_angsmooth[client] == tickcount)
									{
										preframeanglestmp = preframeangles;
										GetClientEyeAngles(client, frameanglestmp);
										//STR_PrintMessageToClient(client, "%d", i_angsmooth[client]);
										SetConVarFloat(FindConVar("host_timescale"), f_host_timescale, true, true);
									}
									outang[client][0] = LinearInterPolation(frameanglestmp[0], preframeanglestmp[0], tickcount - i_angsmooth[client], tickcount);		
									outang[client][1] = LinearInterPolation(frameanglestmp[1], preframeanglestmp[1], tickcount - i_angsmooth[client], tickcount);	
									CopyVector2ToVector3(outang[client], outviewangs);
									//TeleportEntity(client, pos, outviewangs, velocity);
									TeleportEntity(client, NULL_VECTOR, outviewangs, velocity);
									DispatchKeyValueVector(client, "origin", pos);
									i_angsmooth[client] --;
									//STR_PrintMessageToClient(client, "%d", i_angsmooth[client]);
									
								}
								else
								{
									//TeleportEntity(client, NULL_VECTOR, viewangles, velocity);
									//DispatchKeyValueVector(client, "origin", pos);
									
									if(GetEntityMoveType(client) == MOVETYPE_LADDER) 
									{
										buttons = frameinfo_action[FRAME_Buttons];
										TeleportEntity(client, NULL_VECTOR, viewangles, NULL_VECTOR);
									}
									else
									{
										//DispatchKeyValueVector(client, "origin", pos);
										TeleportEntity(client, NULL_VECTOR, viewangles, velocity);
									}
									DispatchKeyValueVector(client, "origin", pos);
									//STR_PrintMessageToAllClients("Client");
								}
								
							}
						}
						else
						{
							//bot会执行这里的代码
							TeleportEntity(client, NULL_VECTOR, viewangles, velocity);
							DispatchKeyValueVector(client, "origin", pos);
							buttons = frameinfo[FRAME_Buttons];
							//STR_PrintMessageToAllClients("Bot");
						}

					}	
					//*/
					//SetEntityFlags(client, frameinfo[FRAME_FFLAG]);//20210421
					//SetEntityMoveType(client, frameinfo[FRAME_MOVETYPE]);//20210421
					
				}
				
				ret = Plugin_Changed;
			}
			
			/*
				When editing a bot it should not increment the current frame
			*/
			if (normalproc)
			{

				Player_IncrementRewindFrame(client);
				curframe = Player_GetRewindFrame(client);
				int length = Player_GetRecordedFramesCount(client);

				//代码实现来自PCI:Movement Reader
				Call_StartForward(g_hOnPlayTick);
				Call_PushCell(client);
				Call_PushCell(curframe);
				Call_Finish();
				decl String:sKeyValue[128];
				Format(sKeyValue, sizeof(sKeyValue), "if (\"OnPlayTick\" in getroottable()) OnPlayTick(self, %d)", curframe);
				SetVariantString(sKeyValue);
				AcceptEntityInput(client, "RunScriptCode");
	
				if (curframe >= length - 2)
				{
					
					Player_SetRewindFrame(client, length - 1);
					Player_SetIsRewinding(client, false);
					SetEntityMoveType(client, MOVETYPE_WALK);
					ResetPlayerReplaySegment(client);
					//STR_PrintMessageToClient(client, "Replay结束");	
					//Player_SetIsRewinding(client, true);	
					//STR_OpenSegmentReplayMenu(client);	
					
				}
			}
		}

	}
	
	//PrintToServer("Client: %d Buttons: %d Angles: %0.2f %0.2f", client, buttons, angles[0], angles[1]);
	return ret;
}



public Action:Resume_record_play(Handle:timer, any:client)
{
	
	Player_SetIsRewinding(client, false);
	SetEntityMoveType(client, MOVETYPE_WALK);		
	Player_SetLastPausedTick(client, Player_GetRewindFrame(client));			
	Player_ResizeRecordFrameList(client, Player_GetRewindFrame(client));
	STR_OpenSegmentReplayMenu(client);	
	return Plugin_Stop;
}



public Action:Resume_play_close(Handle:timer, any:client)
{
	Player_SetIsRewinding(client, false);				
	SetEntityMoveType(client, MOVETYPE_WALK);
	return Plugin_Stop;
}


public Action:Timer_Smooth_Replay(Handle:timer, any:client)
{
	decl Float:fOrigin[3];
	GetClientAbsOrigin(client, fOrigin);
	//STR_DisplayRingToClient(client, STR_LaserSprite, pos_end[client], GetVectorDistance(pos_end[client], pos_end[client], false), 0.1);
	if(GetVectorDistance(pos_end[client], fOrigin, false) < GetVectorDistance(pos_start[client], pos_end[client], false) && GetEntityFlags(client) & FL_ONGROUND)
	{
		ClientCommand(client, "sm_replay_continue %d", client);	
		return Plugin_Stop;
	}
	return Plugin_Continue;	
}



public int GetActiveSlot(int client)
{

	int Slot0 = GetPlayerWeaponSlot(client, 0);
	int Slot1 = GetPlayerWeaponSlot(client, 1);
	int Slot2 = GetPlayerWeaponSlot(client, 2);
	int Slot3 = GetPlayerWeaponSlot(client, 3);
	int Slot4 = GetPlayerWeaponSlot(client, 4);
	int aWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	
	//STR_PrintMessageToClient(client, "%d", Slot0);
	//STR_PrintMessageToClient(client, "%d", Slot1);
	//STR_PrintMessageToClient(client, "%d", Slot2);
	//STR_PrintMessageToClient(client, "%d", Slot3);
	//STR_PrintMessageToClient(client, "%d", Slot4);
	//STR_PrintMessageToClient(client, "%d", aWeapon);
	
	if(aWeapon == Slot0)
		return 1;
	else if(aWeapon == Slot1)
		return 2;
	else if(aWeapon == Slot2)
		return 3;
	else if(aWeapon == Slot3)
		return 4;
	else if(aWeapon == Slot4)
		return 5;
	else
		return -1;
}

public Action:Cmd_ReplaySave(client, args)
{
	if (args == 1)
	{
		decl String:sArg[128];
		GetCmdArg(1, sArg, sizeof(sArg));
		client = StringToInt(sArg);
		Player_SetIsRewinding(client, false);
		//SetEntityMoveType(client, MOVETYPE_WALK);
		//Player_SetIsRewinding(client, true);	
		if(Player_GetIsSegmenting(client) || GetClientTeam(client) == 3) //&& Player_GetIsSegmenting(client) or L4D and L4D2: 2 = survivor 3 = infected
		{	
			char mapbuf[MAX_NAME_LENGTH];
			GetCurrentMap(mapbuf, sizeof(mapbuf));
			
			//char playernamebuf[MAX_NAME_LENGTH];
			//GetClientName(client, playernamebuf, sizeof(playernamebuf));
			
			char newdirbuf[PLATFORM_MAX_PATH];
			BuildPath(Path_SM, newdirbuf, sizeof(newdirbuf), "%s/%s/%s", STR_RootPath, STR_ReplayFolder, mapbuf);
			
			if (!DirExists(newdirbuf))
				CreateDirectory(newdirbuf, 511);
			
			char timebuf[128];
			FormatTime(timebuf, sizeof(timebuf), "%Y %m %d, %H %M %S");

			char namebuf[256];
			FormatEx(namebuf, sizeof(namebuf), "%s (%s)", mapbuf, timebuf);
			
			
			char filename[PLATFORM_MAX_PATH];
			FormatEx(filename, sizeof(filename), "%s/%s.STR", newdirbuf, namebuf);
			
			File file = OpenFile(filename, "wb");
			if (file == null)
			{
				STR_PrintMessageToAllClients("无法保存%N的Replay", client);
				return;
			}
			
			int framecount = Player_GetRecordedFramesCount(client);
			WriteFileCell(file, framecount, 4);
			
			any frameinfo[FRAME_Length];
			
			for (int i = 0; i < framecount; ++i)
			{
				Player_GetFrame(client, i, frameinfo);
				
				for (int j = 0; j < FRAME_Length; ++j)
				{
					WriteFileCell(file, frameinfo[j], 4);
				}
			}
			delete file;
			STR_PrintMessageToAllClients("已保存%N的Replay文件(Cmd)： \"%s\"", client, namebuf);
		} else {
			STR_PrintMessageToAllClients("%N没有在记录Replay.", client);
		}
	}
	else
	{
		STR_PrintMessageToAllClients("%N的Save参数有误.", client);
	}
}



public OnGameEvent(Handle:event, const String:name[], bool:bValue)
{
	if (StrEqual(name, "map_transition"))
	{
		decl String:cmdbuf[128];
		for (new i = 1; i <=  MAXCLIENTS; i++)
		{
			if (IsClientInGame(i) && IsPlayerAlive(i) && Player_GetIsSegmenting(i))
			{
				Format(cmdbuf, sizeof(cmdbuf), "sm_replaysave %d", i);
				ClientCommand(i, cmdbuf);
				
			}
		}
		
	}
	
	
}




public Event_PlayerBotReplace(Event event, const char[] name, bool dontBroadcast)
{
	
	IdleFlags[GetClientOfUserId(GetEventInt(event, "player"))] |= StrEqual(name, "player_bot_replace") ? IN_IDLE : IN_TAKEOVER;
	
}


public Event_PlayerUse(Event event, const char[] name, bool dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (Player_GetIsPlayingReplay(client))
	{
		new entity = GetEventInt(event, "targetid");
		decl String:sName[64];
		GetEntityClassname(entity, sName, sizeof(sName));
		if (StrContains(sName, "prop_door_rotating") != -1)
		{
			if (!GetEntProp(entity, Prop_Send, "m_eDoorState")) AcceptEntityInput(entity, "PlayerOpen", client);
			else AcceptEntityInput(entity, "PlayerClose", client);
		}
	}
}


//============================================================
public Float:GetHealthBuffer(client)
{
	new Float:fHealthTemp = GetEntPropFloat(client, Prop_Send, "m_healthBuffer") - ((GetGameTime() - GetEntPropFloat(client, Prop_Send, "m_healthBufferTime"))*GetConVarFloat(FindConVar("pain_pills_decay_rate")));
	return fHealthTemp > 0.0 ? fHealthTemp : 0.0;
}
//============================================================

//============================================================

public ResetButton(any:client)
{
	//这个函数稍后使用netprop实现
	if (client > 0 && IsClientInGame(client))
	{
		ClientCommand(client, "-attack");
		ClientCommand(client, "-attack2");
		ClientCommand(client, "-duck");
		ClientCommand(client, "-forward");
		ClientCommand(client, "-back");
		ClientCommand(client, "-attack");
		ClientCommand(client, "-use");
		ClientCommand(client, "-left");
		ClientCommand(client, "-right");
	}
	
	//RequestFrame(ResetButton, client);
	//STR_PrintMessageToClient(client, "ButtonResetted");
	//return Plugin_Continue;
}
//============================================================

//============================================================
public SetPlayerMoveTypeNone(any:client)
{
	SetEntityMoveType(client, MOVETYPE_NONE);
	//return Plugin_Continue;
}
//============================================================

//============================================================
public Action:Cmd_loadFile(client, args)
{
	if (args == 2)
	{
		decl String:sArg[128];
		GetCmdArg(1, sArg, sizeof(sArg));
		client = StringToInt(sArg);
		if (client > 0 && IsClientInGame(client))
		{
			GetCmdArg(2, sArg, sizeof(sArg));
			char info[512];
			info = sArg;
			
			char mapbuf[MAX_NAME_LENGTH];
			GetCurrentMap(mapbuf, sizeof(mapbuf));
			
			char filepath[PLATFORM_MAX_PATH];
			BuildPath(Path_SM, filepath, sizeof(filepath), "%s/%s/%s/%s", STR_RootPath, STR_ReplayFolder, mapbuf, info);
			
			File file = OpenFile(filepath, "rb");
			
			if (file == null)
			{
				STR_PrintMessageToClient(client, "\"%s\" 无法打开", info);
				return Plugin_Continue;
			}
			
			//ResetPlayerReplaySegment(client);
			
			int framecount;		
			ReadFileCell(file, framecount, 4);
			//PrintToChat(client, "%d frames", framecount);
			Player_CreateFrameArray(client);		
			any frameinfo[FRAME_Length];			
			for (int i = 0; i < framecount; ++i)
			{			
				ReadFile(file, frameinfo, sizeof(frameinfo), 4);
				
				Player_PushFrame(client, frameinfo);
			}
			delete file;
			
			if(Player_GetStopFrame(client) == 0) 
			{
				Player_SetStopFrame(client, 99999);
				STR_PrintMessageToClient(client, "%N的StopFrame参数已自动设置为99999", client);
			}
			STR_PrintMessageToAllClients("%N 已加载Replay(Cmd) \"%s\"", client, info);
			g_bIsFileLoad[client] = true;
	
		}
	}
	return Plugin_Handled;
}
//============================================================

//============================================================
public Action:Cmd_Replay_Continue(client, args)
{
	f_host_timescale = GetConVarFloat(FindConVar("host_timescale"));	
	if (args == 1)
	{
		decl String:sArg[128];
		GetCmdArg(1, sArg, sizeof(sArg));
		client = StringToInt(sArg);
		if(g_bIsFileLoad[client])
		{
			Player_SetHasRun(client, true);				
			Player_SetPlayingReplay(client, true);
			Player_SetRewindFrame(client, Player_GetStartFrame(client));
			Player_SetIsRewinding(client, false);	
			//ResetPlayerReplaySegment(client);
			
			i_linesmooth[client] = Player_GetEndFrame(client) - Player_GetStartFrame(client);
			if(i_linesmooth[client] < 1)
			{
				//STR_PrintMessageToClient(client, "开始和结束帧设置不正确");
				i_linesmooth[client] = 1;
			}
			//STR_PrintMessageToClient(client, "%d", i_linesmooth[client]);
		}
		else
		{
			STR_PrintMessageToAllClients("%N的Replay文件没有加载.", client);
		}
		
	}
	return Plugin_Handled;
}
//============================================================

//============================================================
public Action:Cmd_Test(client, args)
{
	
	if (args == 2)
	{
		decl String:sArg[128];
		GetCmdArg(1, sArg, sizeof(sArg));
		client = StringToInt(sArg);
		GetCmdArg(2, sArg, sizeof(sArg));
		int client_2 = StringToInt(sArg);

		decl String:sTrace[512];
		float pos[2][3];
		GetClientAbsOrigin(client, pos[0]);
		GetClientAbsOrigin(client_2, pos[1]);

		Format(sTrace, sizeof(sTrace), "DebugDrawLine(Vector(%f, %f, %f), Vector(%f, %f, %f), 0, 0, 255, true, 86400);", pos[0][0], pos[0][1], pos[0][2], pos[1][0], pos[1][1], pos[1][2]);
		SetVariantString(sTrace);
		AcceptEntityInput(client, "RunScriptCode");


		/*
		decl String:sArg[128];
		GetCmdArg(1, sArg, sizeof(sArg));
		int entity = StringToInt(sArg);
		decl Float:VecOrigin[3];
		GetEntPropVector(entity, Prop_Send, "m_vecOrigin", VecOrigin);
		STR_PrintMessageToAllClients("%f %f %f.", VecOrigin[0], VecOrigin[1], VecOrigin[2]);
		STR_PrintMessageToAllClients("ok.");
		*/
	}
	else
	{
		//SDKCall(g_hGoAwayFromKeyboard, client);
		STR_PrintMessageToAllClients("参数错误(需要两个参数).");
	}
	return Plugin_Handled;
}
//============================================================

//============================================================
public Action:Cmd_Reset_Replay(client, args)
{
	if (args == 1)
	{
		decl String:sArg[128];
		GetCmdArg(1, sArg, sizeof(sArg));
		client = StringToInt(sArg);
		ResetPlayerReplaySegment(client);
		STR_PrintMessageToClient(client, "Replay Reseted");
		
	}
	return Plugin_Handled;
}
//============================================================

//============================================================
public Action:Cmd_Replay_Record(client, args)
{
	if (args == 1)
	{
		
		decl String:sArg[128];
		GetCmdArg(1, sArg, sizeof(sArg));
		client = StringToInt(sArg);
		
		Player_SetIsSegmenting(client, true);
		Player_SetIsRewinding(client, false);
		Player_SetHasRun(client, false);
		Player_SetPlayingReplay(client, false);
		
		Player_CreateFrameArray(client);
		Player_SetRewindFrame(client, 0);
		STR_PrintMessageToAllClients("开始记录%N的Rplay(Cmd)...", client);
		STR_OpenSegmentReplayMenu(client);

	}
	return Plugin_Handled;
}
//============================================================

//============================================================
public Action:Cmd_Smooth_Replay(client, args)
{
	
	if (args == 1)
	{
		decl String:sArg[128];
		GetCmdArg(1, sArg, sizeof(sArg));
		client = StringToInt(sArg);
		if(g_bIsFileLoad[client])
		{	
			
			//STR_PrintMessageToAllClients("%N", client);
			any frameinfo[FRAME_Length];
			
			float markpos[3];	
			Player_GetFrame(client, Player_GetStartFrame(client), frameinfo);
			GetArrayVector3(frameinfo, FRAME_PosX, pos_start[client]);
			
			Player_GetFrame(client, Player_GetEndFrame(client), frameinfo);
			GetArrayVector3(frameinfo, FRAME_PosX, pos_end[client]);
			
			markpos[0] = pos_end[client][0];
			markpos[1] = pos_end[client][1];
			markpos[2] = pos_end[client][2] + 15.0;
			
			float viewangles[3];	
			viewangles[0] = 0.0;
			viewangles[1] = frameinfo[FRAME_AngY];
			viewangles[2] = 0.0;
			
			STR_PrintMessageToAllClients("%N的Smooth设置成功", client);
			
			/*
			new prop = CreateEntityByName("prop_dynamic");
			SetEntityModel(prop, "models/extras/info_speech.mdl");
			DispatchKeyValue(prop, "targetname", "st_speech");
			DispatchKeyValue(prop, "disableshadows", "1");
			TeleportEntity(prop, markpos, viewangles, NULL_VECTOR);
			*/
			
			IsLinear_Transition[client] = true;
			//STR_DisplayRingToClient(client, STR_LaserSprite, pos_end[client], GetVectorDistance(pos_start[client], pos_end[client], false)*2, 60.0);
			CreateTimer(0.01, Timer_Smooth_Replay, client, TIMER_REPEAT);
		}
		else
		{
			STR_PrintMessageToAllClients("%N的Replay文件没有加载.", client);
		}
		
	}
	return Plugin_Handled;
}
//============================================================

//============================================================
public Action:Test(Handle:timer, any:client)
{
	
	return Plugin_Continue;
	//return Plugin_Stop;
}
//============================================================


//============================================================
public Action:Cmd_ReplayPause(client, args)
{
	if (args == 1)
	{
		decl String:sArg[128];
		GetCmdArg(1, sArg, sizeof(sArg));
		client = StringToInt(sArg);
		if (client > 0 && IsClientInGame(client))
		{
			PauseWhilePlaying[client] = true;
			Player_SetIsRewinding(client, true);
			RequestFrame(SetPlayerMoveTypeNone, client);//暂时没起作用？
			STR_PrintMessageToAllClients("%N 的Replay已暂停.", client);			
		}
		
	}
	else
	{
		STR_PrintMessageToClient(client, "输入参数错误");
	}
	return Plugin_Handled;
}
//============================================================

//============================================================
public Action:Cmd_ReplayUnPause(client, args)
{
	if (args == 1)
	{
		decl String:sArg[128];
		GetCmdArg(1, sArg, sizeof(sArg));
		client = StringToInt(sArg);
		if (client > 0 && IsClientInGame(client))
		{
			PauseWhilePlaying[client] = false;

			Player_SetIsRewinding(client, false);
			STR_PrintMessageToAllClients("%N 的Replay已取消暂停.", client);			
		}
		
	}
	else
	{
		STR_PrintMessageToClient(client, "输入参数错误");
	}
	return Plugin_Handled;
}
//============================================================

//============================================================
public Action:Cmd_Start_Frame(client, args)
{
	if (args == 2)
	{
		decl String:sArg[128];
		GetCmdArg(1, sArg, sizeof(sArg));
		client = StringToInt(sArg);
		if (client > 0 && IsClientInGame(client))
		{
			GetCmdArg(2, sArg, sizeof(sArg));
			Player_SetStartFrame(client, StringToInt(sArg));
			STR_PrintMessageToAllClients("%N 的Startframe参数已设置为%d", client, StringToInt(sArg));
			
		}
		
	}
	else
	{
		STR_PrintMessageToClient(client, "输入参数错误");
	}
	return Plugin_Handled;
}
//============================================================

//============================================================
public Action:Cmd_End_Frame(client, args)
{
	if (args == 2)
	{
		decl String:sArg[128];
		GetCmdArg(1, sArg, sizeof(sArg));
		client = StringToInt(sArg);
		if (client > 0 && IsClientInGame(client))
		{
			GetCmdArg(2, sArg, sizeof(sArg));
			Player_SetEndFrame(client, StringToInt(sArg));
			STR_PrintMessageToAllClients("%N 的Endframe参数已设置为%d", client, StringToInt(sArg));
			
		}
		
	}
	else
	{
		STR_PrintMessageToClient(client, "输入参数错误");
	}
	return Plugin_Handled;
}
//============================================================

//============================================================
public Action:Cmd_Stop_Frame(client, args)
{
	if (args == 2)
	{
		decl String:sArg[128];
		GetCmdArg(1, sArg, sizeof(sArg));
		client = StringToInt(sArg);
		if (client > 0 && IsClientInGame(client))
		{
			GetCmdArg(2, sArg, sizeof(sArg));
			Player_SetStopFrame(client, StringToInt(sArg));
			STR_PrintMessageToAllClients("%N 的Stopframe参数已设置为%d", client, StringToInt(sArg));
		}
		
	}
	else
	{
		STR_PrintMessageToClient(client, "输入参数错误");
	}
	return Plugin_Handled;
}
//============================================================

//============================================================//2021.3.28加入分离replay功能
public Action:Cmd_ReplaySplit(client, args)
{
	if (args == 3)
	{
		decl String:sArg[128];
		GetCmdArg(1, sArg, sizeof(sArg));
		client = StringToInt(sArg);
		if (client > 0 && IsClientInGame(client))
		{
			if(g_bIsFileLoad[client])
			{
				int framecount = Player_GetRecordedFramesCount(client);
				GetCmdArg(2, sArg, sizeof(sArg));
				new frame_start = StringToInt(sArg);
				GetCmdArg(3, sArg, sizeof(sArg));
				new frame_end = StringToInt(sArg);
				if(frame_start < frame_end && frame_end <= framecount && frame_start >= 0)
				{
				
					char mapbuf[MAX_NAME_LENGTH];
					GetCurrentMap(mapbuf, sizeof(mapbuf));
					
					char playernamebuf[MAX_NAME_LENGTH];
					GetClientName(client, playernamebuf, sizeof(playernamebuf));
					
					char newdirbuf[PLATFORM_MAX_PATH];
					BuildPath(Path_SM, newdirbuf, sizeof(newdirbuf), "%s/%s/%s", STR_RootPath, STR_ReplayFolder, mapbuf);
					
					if (!DirExists(newdirbuf))
						CreateDirectory(newdirbuf, 511);
					
					char timebuf[128];
					FormatTime(timebuf, sizeof(timebuf), "%Y %m %d, %H %M %S");
					
					char namebuf[256];
					//FormatEx(namebuf, sizeof(namebuf), "[%d] %s (%s)", steamid, playernamebuf, timebuf);
					//FormatEx(namebuf, sizeof(namebuf), "[%s] %s (%s)", mapbuf, playernamebuf, timebuf);
					FormatEx(namebuf, sizeof(namebuf), "[%s] (%s)", mapbuf, timebuf);//去掉玩家名字，防止无法保存replay
					
					char filename[PLATFORM_MAX_PATH];
					FormatEx(filename, sizeof(filename), "%s/%s_Splited.STR", newdirbuf, namebuf);
					
					File file = OpenFile(filename, "wb");
					
					if (file == null)
					{
						STR_PrintMessageToClient(client, "无法保存Replay");
						return Plugin_Handled;
					}
					
					WriteFileCell(file, frame_end - frame_start + 1, 4);
					
					any frameinfo[FRAME_Length];
					
					for (int i = frame_start; i <= frame_end; ++i)
					{
						Player_GetFrame(client, i, frameinfo);
						
						for (int j = 0; j < FRAME_Length; ++j)
						{
							WriteFileCell(file, frameinfo[j], 4);
						}
					}
					
					delete file;
					STR_PrintMessageToClient(client, "保存Replay文件： \"%s_Splited\"", namebuf);
				}
				else
				{
					STR_PrintMessageToAllClients("%N 分离Replay参数设置错误，请检查.", client);
				}
			}
			else
			{
				STR_PrintMessageToAllClients("请先为玩家%N加载Replay.", client);
			}
		}
		
	}
	else
	{
		STR_PrintMessageToClient(client, "输入参数错误");
	}
	return Plugin_Handled;
}
//============================================================

//============================================================
public Action:Cmd_Remove_Slot(client, args)
{
	if (args == 2)
	{
		decl String:sArg[128];
		GetCmdArg(1, sArg, sizeof(sArg));
		client = StringToInt(sArg);
		if (client > 0 && IsClientInGame(client))
		{
			GetCmdArg(2, sArg, sizeof(sArg));
			int weapon = GetPlayerWeaponSlot(client, StringToInt(sArg) - 1);
			AcceptEntityInput(weapon, "Kill");
			if(StringToInt(sArg) == 1) STR_PrintMessageToAllClients("%N 的主武器已移除", client);
			if(StringToInt(sArg) == 2) STR_PrintMessageToAllClients("%N 的副武器已移除", client);
			if(StringToInt(sArg) == 3) STR_PrintMessageToAllClients("%N 的投掷品已移除", client);
			if(StringToInt(sArg) == 4) STR_PrintMessageToAllClients("%N 的栏位4物品已移除", client);
			if(StringToInt(sArg) == 5) STR_PrintMessageToAllClients("%N 的栏位5物品已移除", client);
			
		}
		
	}
	else
	{
		STR_PrintMessageToClient(client, "输入参数错误");
	}
	return Plugin_Handled;
}
//============================================================



//========================================================================================================================
//Tools ScMp
//========================================================================================================================
stock bool:ST_Idle(client, bool:bType = false)
{
	if (IsClientInGame(client) && !IsPlayerABot(client))
	{
		if (bType)
		{
			if (GetClientTeam(client) == 1)
			{
				SDKCall(g_hTakeOverBot, client);
				return true;
			}
		}
		else
		{
			if (GetClientTeam(client) == 2 && IsPlayerAlive(client))
			{
				if (GetConVarBool(g_ConVar_ReplayIdleAnytime))
				{
					SDKCall(g_hGoAwayFromKeyboard, client);
					PrintToChatAll("[ST_Idle] %N is now idle.", client);
					return true;
				}
				for (new i = 1; i <= MaxClients; i++)
				{
					if (IsClientInGame(i) && !IsPlayerABot(i) && IsPlayerAlive(i) && client != i && GetClientTeam(i) == 2)
					{
						SDKCall(g_hGoAwayFromKeyboard, client);
						PrintToChatAll("%N is now idle.", client);
						return true;
					}
				}
			}
		}
	}
	return false;
}

//============================================================

//============================================================
public bool:IsPlayer(client)
{
	if (client > 0 && client <= MaxClients && IsClientInGame(client))
	{
		return true;
	}
	return false;
}

//============================================================
public bool:IsPlayerABot(client)
{
	if (GetEntityFlags(client) & FL_FAKECLIENT)
	{
		return true;
	}
	return false;
}


//============================================================
public void STR_DisplayRingToClient(int client, int sprite, float[3] points, float radius, float lifetime)
{
	TE_SetupBeamRingPoint(points, radius, radius + 5.0, sprite, 0, 0, 0, lifetime, 2.0, 0.0, {255, 0, 255, 255}, 0, 0);
	//TE_SendToClient(client);
	//TE_SetupBeamRingPoint(const Float:center[3], Float:Start_Radius, Float:End_Radius, ModelIndex, HaloIndex, StartFrame, FrameRate, Float:Life, Float:Width, Float:Amplitude, const Color[4], Speed, Flags)
	//TE_SetupBeamPoints(const float start[3], const float end[3], int ModelIndex, int HaloIndex, int StartFrame, int FrameRate, float Life, float Width, float EndWidth, int FadeLength, float Amplitude, const int Color[4], int Speed)
	
	
}


//STR_DisplayTraceToClient(client, STR_LaserSprite, points, 30.0);
public void STR_DisplayTraceToClient(int client, int sprite, float[20][3] points, float lifetime, int color[4])
{

	TE_SetupBeamPoints(points[0], points[1], sprite, 0, 0, 0, lifetime, 1.0, 1.0, 5, 0.0, color, 0);
	//TE_SendToClient(client);
	TE_SendToAll();
	
	TE_SetupBeamPoints(points[1], points[2], sprite, 0, 0, 0, lifetime, 1.0, 1.0, 5, 0.0, color, 0);
	//TE_SendToClient(client);
	TE_SendToAll();
	
	TE_SetupBeamPoints(points[2], points[3], sprite, 0, 0, 0, lifetime, 1.0, 1.0, 5, 0.0, color, 0);
	//TE_SendToClient(client);
	TE_SendToAll();
	
	TE_SetupBeamPoints(points[3], points[4], sprite, 0, 0, 0, lifetime, 1.0, 1.0, 5, 0.0, color, 0);
	//TE_SendToClient(client);
	TE_SendToAll();
	
	TE_SetupBeamPoints(points[4], points[5], sprite, 0, 0, 0, lifetime, 1.0, 1.0, 5, 0.0, color, 0);
	//TE_SendToClient(client);
	TE_SendToAll();
	
	TE_SetupBeamPoints(points[5], points[6], sprite, 0, 0, 0, lifetime, 1.0, 1.0, 5, 0.0, color, 0);
	//TE_SendToClient(client);
	TE_SendToAll();
	
	TE_SetupBeamPoints(points[6], points[7], sprite, 0, 0, 0, lifetime, 1.0, 1.0, 5, 0.0, color, 0);
	//TE_SendToClient(client);
	TE_SendToAll();
	
	TE_SetupBeamPoints(points[7], points[8], sprite, 0, 0, 0, lifetime, 1.0, 1.0, 5, 0.0, color, 0);
	//TE_SendToClient(client);
	TE_SendToAll();
	
	TE_SetupBeamPoints(points[8], points[9], sprite, 0, 0, 0, lifetime, 1.0, 1.0, 5, 0.0, color, 0);
	//TE_SendToClient(client);
	TE_SendToAll();
	
	TE_SetupBeamPoints(points[9], points[10], sprite, 0, 0, 0, lifetime, 1.0, 1.0, 5, 0.0, color, 0);
	//TE_SendToClient(client);
	TE_SendToAll();
	
	TE_SetupBeamPoints(points[10], points[11], sprite, 0, 0, 0, lifetime, 1.0, 1.0, 5, 0.0, color, 0);
	//TE_SendToClient(client);
	TE_SendToAll();
	
	TE_SetupBeamPoints(points[11], points[12], sprite, 0, 0, 0, lifetime, 1.0, 1.0, 5, 0.0, color, 0);
	//TE_SendToClient(client);
	TE_SendToAll();
	
	TE_SetupBeamPoints(points[12], points[13], sprite, 0, 0, 0, lifetime, 1.0, 1.0, 5, 0.0, color, 0);
	//TE_SendToClient(client);
	TE_SendToAll();
	
	TE_SetupBeamPoints(points[13], points[14], sprite, 0, 0, 0, lifetime, 1.0, 1.0, 5, 0.0, color, 0);
	//TE_SendToClient(client);
	TE_SendToAll();
	
	TE_SetupBeamPoints(points[14], points[15], sprite, 0, 0, 0, lifetime, 1.0, 1.0, 5, 0.0, color, 0);
	//TE_SendToClient(client);
	TE_SendToAll();
	
	TE_SetupBeamPoints(points[15], points[16], sprite, 0, 0, 0, lifetime, 1.0, 1.0, 5, 0.0, color, 0);
	//TE_SendToClient(client);
	TE_SendToAll();
	
	TE_SetupBeamPoints(points[16], points[17], sprite, 0, 0, 0, lifetime, 1.0, 1.0, 5, 0.0, color, 0);
	//TE_SendToClient(client);
	TE_SendToAll();
	
	TE_SetupBeamPoints(points[17], points[18], sprite, 0, 0, 0, lifetime, 1.0, 1.0, 5, 0.0, color, 0);
	//TE_SendToClient(client);
	TE_SendToAll();
	
	TE_SetupBeamPoints(points[18], points[19], sprite, 0, 0, 0, lifetime, 1.0, 1.0, 5, 0.0, color, 0);
	//TE_SendToClient(client);
	TE_SendToAll();
	
}

public Action:STR_ReplayDrawTrace(client, args)
{
	
	if (args == 1)
	{
		decl String:sArg[128];
		GetCmdArg(1, sArg, sizeof(sArg));
		client = StringToInt(sArg);
		if(g_bIsFileLoad[client])
		{	
			//STR_PrintMessageToAllClients("绘制%N的Replay轨迹.", client);
			//Timer_Draw_Trace[client] = CreateTimer(0.1, Draw_Trace, client, TIMER_REPEAT);
			any frameinfo[2][FRAME_Length];
			int length = Player_GetRecordedFramesCount(client);
			float pos[2][3];
			decl String:sTrace[512];
			decl String:sPerspective[64];//是否透视
			if(GetConVarBool(b_ReplayDebug))
			{
				sPerspective = "true";
			}
			else
			{
				sPerspective = "false";
			}
			for(new i = 1; i < length - 1; i++)
			{
				
				Player_GetFrame(client, i, frameinfo[0]);
				GetArrayVector3(frameinfo[0], FRAME_PosX, pos[0]);
				Player_GetFrame(client, i + 1, frameinfo[1]);
				GetArrayVector3(frameinfo[1], FRAME_PosX, pos[1]);
				
				Format(sTrace, sizeof(sTrace), "DebugDrawLine(Vector(%f, %f, %f), Vector(%f, %f, %f), 0, 255, 0, %s, 86400);", pos[0][0], pos[0][1], pos[0][2], pos[1][0], pos[1][1], pos[1][2], "true");
				SetVariantString(sTrace);
				AcceptEntityInput(client, "RunScriptCode");
			}
			STR_PrintMessageToAllClients("绘制%N的Replay轨迹.", client);
		}
		else
		{
			SetVariantString("DebugDrawClear()");
			AcceptEntityInput(client, "RunScriptCode");
			STR_PrintMessageToAllClients("请先为玩家%N加载Replay.", client);
			return Plugin_Handled;
		}
	}
	else
	{
		STR_PrintMessageToClient(client, "参数错误(输入一个参数).");
		
	}
	
	return Plugin_Handled;
}

public Action:STR_ReplayDrawTrace_PosMap(client, args)
{
	
	if (args == 1)
	{
		decl String:sArg[128];
		GetCmdArg(1, sArg, sizeof(sArg));
		client = StringToInt(sArg);
		if(g_bIsFileLoad[client])
		{	
			//STR_PrintMessageToAllClients("绘制%N的Replay轨迹.", client);
			//Timer_Draw_Trace[client] = CreateTimer(0.1, Draw_Trace, client, TIMER_REPEAT);
			float fPosMap[3];
			fPosMap[0] = GetConVarFloat(g_ConVar_PosMap_x);
			fPosMap[1] = GetConVarFloat(g_ConVar_PosMap_y);
			fPosMap[2] = GetConVarFloat(g_ConVar_PosMap_z);
			
			any frameinfo[2][FRAME_Length];
			int length = Player_GetRecordedFramesCount(client);
			float pos[2][3];
			decl String:sTrace[512];
			decl String:sPerspective[64];//是否透视
			if(GetConVarBool(b_ReplayDebug))
			{
				sPerspective = "true";
			}
			else
			{
				sPerspective = "false";
			}
			for(new i = 1; i < length - 1; i++)
			{
				
				Player_GetFrame(client, i, frameinfo[0]);
				GetArrayVector3(frameinfo[0], FRAME_PosX, pos[0]);
				Player_GetFrame(client, i + 1, frameinfo[1]);
				GetArrayVector3(frameinfo[1], FRAME_PosX, pos[1]);
				
				Format(sTrace, sizeof(sTrace), "DebugDrawLine(Vector(%f, %f, %f), Vector(%f, %f, %f), 255, 0, 0, %s, 86400);", pos[0][0] + fPosMap[0], pos[0][1] + fPosMap[1], pos[0][2] + fPosMap[2], pos[1][0] + fPosMap[0], pos[1][1] + fPosMap[1], pos[1][2] + fPosMap[2], "true");
				SetVariantString(sTrace);
				AcceptEntityInput(client, "RunScriptCode");
			}
			STR_PrintMessageToAllClients("绘制%N的Replay轨迹(Def Trick.).", client);
		}
		else
		{
			SetVariantString("DebugDrawClear()");
			AcceptEntityInput(client, "RunScriptCode");
			STR_PrintMessageToAllClients("请先为玩家%N加载Replay.", client);
			return Plugin_Handled;
		}
	}
	else
	{
		STR_PrintMessageToClient(client, "参数错误(输入一个参数).");
		
	}
	
	return Plugin_Handled;
}


public Action:STR_ReplayCloseDrawTrace(client, args)
{
	
	if (args == 1)
	{
		decl String:sArg[128];
		GetCmdArg(1, sArg, sizeof(sArg));
		client = StringToInt(sArg);
		if(client < 1) 
		{
			return Plugin_Handled;
		}
		/*
		if(Timer_Draw_Trace[client])
		{
			KillTimer(Timer_Draw_Trace[client]);
			
		}
		else
		{
			STR_PrintMessageToAllClients("%N没有在绘制轨迹.", client);
		}
		*/
		SetVariantString("DebugDrawClear()");
		AcceptEntityInput(client, "RunScriptCode");
		STR_PrintMessageToAllClients("轨迹绘制已关闭.");
	}
	
	return Plugin_Handled;
}

/*
public Action:Draw_Trace(Handle:timer, any:client)//如果采用新方法(DebugDrawLine)，这个函数就不会被调用
{
	if(g_bIsFileLoad[client])
	{
		any frameinfo[FRAME_Length];
		int length = Player_GetRecordedFramesCount(client);
		//STR_PrintMessageToAllClients("%d.", length);
		if(!length)
		{
			STR_PrintMessageToAllClients("%N的轨迹绘制停止.", client);
			return Plugin_Stop;
		}
		float draw_points[20][3];
		int color[4] = {0, 255, 0, 255};
		
		for(new i = 0; i < 20; i++)
		{
			Player_GetFrame(client, Trace_Line[client], frameinfo);
			GetArrayVector3(frameinfo, FRAME_PosX, draw_points[i]);
			Trace_Line[client] += 2;
		}
		Trace_Line[client] -= 4;
		if(Trace_Line[client] > length - 41)
		{
			Trace_Line[client] = 0;
		}
		
		//for(new i = 0; i < 3; i++)
		//{
		//	color[i] = GetRandomInt(0, 255);//轨迹随机颜色
		//}
		
		color[3] = 255;
		
		STR_DisplayTraceToClient(client, STR_LaserSprite, draw_points, 60.0, color);
	}
	else
	{
		KillTimer(Timer_Draw_Trace[client]);
	}
	return Plugin_Continue;	
}
*/
