#if defined MENUS_INCLUDED
#endinput
#endif
#define MENUS_INCLUDED

/*
	Main plugin menu entries
*/
enum
{	
	/*
		Menu commands before or while a replay is being created
	*/
	SEG_Start,
	SEG_Resume,
	SEG_Resume_Now,
	SEG_Pause,
	SEG_GoBack,
	SEG_Play,
	SEG_Stop,
	SEG_EXIT,
	SEG_LoadFromFile,
	Step_Back,
	Step_Forward,
	Rewind,
	Fastforward,
	SEG_Play_Trace,
	SEG_Play_Trace_Close,
	SEG_Play_Trace_PosMap,
	
	/*
		Menu commands after a replay is created
	*/	
	MOV_Resume,
	MOV_Resume_Close,
	MOV_NewFrom,
	MOV_Stop,
	MOV_Pause,
	MOV_ContinueFrom,
	MOV_SaveToFile,
	MOV_Blank,
	JumpToStart,
	JumpToEnd,
	
	
	
	
	SEG_Start_All,
	SEG_Resume_All,
	SEG_Resume_Now_All,
	SEG_Pause_All,
	SEG_GoBack_All,
	SEG_Play_All,
	SEG_Stop_All,
	SEG_LoadFromFile_All,
	Step_Back_All,
	Step_Forward_All,
	Rewind_All,
	Fastforward_All,
	
	MOV_Resume_All,
	MOV_Resume_Close_All,
	MOV_NewFrom_All,
	MOV_Stop_All,
	MOV_Pause_All,
	MOV_ContinueFrom_All,
	MOV_SaveToFile_All,
	MOV_Blank_All,
	JumpToStart_All,
	JumpToEnd_All,
	RewindSpeed_All,
	MOV_Replay2Record,
	
	Menu_All,
};

/*
	Converts the enum value "data" into a string and sets it as the info value to a menu item.
*/
public void Menu_AddEnumEntry(Handle menu, any data, char[] displaystr)
{
	char buf[64];
	IntToString(data, buf, sizeof(buf));
	AddMenuItem(menu, buf, displaystr);
}
