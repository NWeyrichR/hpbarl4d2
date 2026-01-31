#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>
#include <gamma_colors>

#pragma newdecls required



public Plugin myinfo = {
    name = "L4D2 Fortnite Health Bar (Full Fix)",
    author = "AI Assistant",
    description = "Barra alta, cor preta na morte e sem bugs",
    version = "2.6"
}


float g_fBlockBar[2048]; // Armazena o tempo de bloqueio por vítima
int g_iNextBarSlot[MAXPLAYERS+1]; 
float g_fNextAllowedBar[MAXPLAYERS+1][2048];
int ge_iOwner[2048];
bool g_bState[MAXPLAYERS+1];
Handle g_hCookie;
int g_iSlotSpriteRef[MAXPLAYERS+1][5]; // Guarda o Ref do Sprite nos 5 slots
int g_iSlotVictim[MAXPLAYERS+1][5];    // Guarda quem é a vítima de cada slot

int g_iBlockBarRef[2048];              // EntRef do alvo bloqueado (evita reuso de index)
float g_fBlockBarUntil[2048];          // Tempo ate quando o bloqueio vale

ConVar g_cvBarsRate, g_cvBarsBurst, g_cvBarsLinger, g_cvBarsMaxScale;
float g_fBarTokens[MAXPLAYERS+1];
float g_fBarLastTokenUpdate[MAXPLAYERS+1];
float g_fSlotLastDamage[MAXPLAYERS+1][5];
int g_iTankHP[MAXPLAYERS+1];
int g_iTankRef[MAXPLAYERS+1];

char g_sBarPath[] = "materials/hpbar/bar.vmt";
#define BAR_HEIGHT 90.0

public void OnPluginStart() {
    RegConsoleCmd("sm_bars", Command_ToggleBars);
    g_cvBarsRate = CreateConVar("sm_bars_rate", "12.0", "Limite de barras novas por segundo (por jogador). 0 = desativado");
    g_cvBarsBurst = CreateConVar("sm_bars_burst", "6.0", "Burst maximo de barras novas (por jogador).");
    g_cvBarsLinger = CreateConVar("sm_bars_linger", "1.2", "Tempo (seg) para a barra ficar na tela apos o ultimo hit antes de comecar a sumir.");
    g_cvBarsMaxScale = CreateConVar("sm_bars_max_scale", "0.22", "Escala maxima da barra (cap) para distancias longas. 0 = sem limite");
    g_hCookie = RegClientCookie("fortnite_bars_state", "Estado das barras", CookieAccess_Protected);
    HookEvent("player_hurt", Event_Damage);
    HookEvent("infected_hurt", Event_Damage);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("player_spawn", Event_PlayerSpawn);
}


public void OnMapStart() {
    PrecacheModel(g_sBarPath, true);
    AddFileToDownloadsTable("materials/hpbar/bar.vmt");
    AddFileToDownloadsTable("materials/hpbar/bar.vtf");
}

public void OnClientCookiesCached(int client) {
    char buff[4]; GetClientCookie(client, g_hCookie, buff, sizeof(buff));
    g_bState[client] = (buff[0] == '\0' || StringToInt(buff) == 1);
}

public Action Command_ToggleBars(int client, int args) {
    if (client == 0) return Plugin_Handled;
    g_bState[client] = !g_bState[client];
    char b[4]; IntToString(g_bState[client], b, sizeof(b)); SetClientCookie(client, g_hCookie, b);
    GCPrintToChat(client, "{default}[{green}BARS{default}] Barra: %s", g_bState[client] ? "{green}ON" : "{red}OFF");
    return Plugin_Handled;
}



public Action OnTransmit(int entity, int client) {
    if (ge_iOwner[entity] != client) return Plugin_Stop;
    return Plugin_Continue;
}

bool IsVictimDyingOrDead(int victim)
{
    if (victim <= 0 || victim >= 2048 || !IsValidEntity(victim)) return true;

    int lifeState = 0;
    if (HasEntProp(victim, Prop_Send, "m_lifeState"))
        lifeState = GetEntProp(victim, Prop_Send, "m_lifeState");
    else if (HasEntProp(victim, Prop_Data, "m_lifeState"))
        lifeState = GetEntProp(victim, Prop_Data, "m_lifeState");
    else if (victim <= MaxClients)
        return !IsPlayerAlive(victim);

    if (lifeState != 0) return true;

    int health = 0;
    if (HasEntProp(victim, Prop_Send, "m_iHealth"))
        health = GetEntProp(victim, Prop_Send, "m_iHealth");
    else if (HasEntProp(victim, Prop_Data, "m_iHealth"))
        health = GetEntProp(victim, Prop_Data, "m_iHealth");
    else
        return false;

    return (health <= 0);
}

bool IsVictimTank(int victim)
{
    if (victim <= 0 || victim > MaxClients || !IsClientInGame(victim)) return false;
    if (GetClientTeam(victim) != 3) return false;
    if (!HasEntProp(victim, Prop_Send, "m_zombieClass")) return false;
    return (GetEntProp(victim, Prop_Send, "m_zombieClass") == 8);
}

bool ShouldBlockTankDeathFromHurt(Event event, int victim)
{
    if (!IsVictimTank(victim)) return false;

    int damage = event.GetInt("dmg_health");
    if (damage <= 0) damage = event.GetInt("amount");
    if (damage <= 0) return false;

    int eventHP = event.GetInt("health");
    if (eventHP < 0) eventHP = 0;

    int ref = EntIndexToEntRef(victim);
    if (g_iTankRef[victim] != ref) {
        g_iTankRef[victim] = ref;
        g_iTankHP[victim] = eventHP + damage;
    }

    g_iTankHP[victim] -= damage;
    if (eventHP > 0 && eventHP < g_iTankHP[victim]) g_iTankHP[victim] = eventHP;

    return (g_iTankHP[victim] <= 0);
}

bool IsBarBlocked(int victim)
{
    if (victim <= 0 || victim >= 2048 || !IsValidEntity(victim)) return false;
    int ref = EntIndexToEntRef(victim);
    return (g_iBlockBarRef[victim] != 0 && ref == g_iBlockBarRef[victim] && GetGameTime() < g_fBlockBarUntil[victim]);
}

void BlockBarForVictim(int victim, float duration)
{
    if (victim <= 0 || victim >= 2048 || !IsValidEntity(victim)) return;
    g_iBlockBarRef[victim] = EntIndexToEntRef(victim);
    g_fBlockBarUntil[victim] = GetGameTime() + duration;
    g_fBlockBar[victim] = g_fBlockBarUntil[victim];
}

bool ConsumeBarToken(int attacker)
{
    if (attacker <= 0 || attacker > MaxClients) return false;

    float rate = g_cvBarsRate.FloatValue;
    float burst = g_cvBarsBurst.FloatValue;
    if (rate <= 0.0 || burst <= 0.0) return true; // desativado

    float now = GetGameTime();
    float dt = now - g_fBarLastTokenUpdate[attacker];
    if (dt < 0.0) dt = 0.0;

    g_fBarTokens[attacker] += dt * rate;
    if (g_fBarTokens[attacker] > burst) g_fBarTokens[attacker] = burst;
    g_fBarLastTokenUpdate[attacker] = now;

    if (g_fBarTokens[attacker] < 1.0) return false;
    g_fBarTokens[attacker] -= 1.0;
    return true;
}

void KillBarsForVictim(int victim)
{
    if (victim <= 0 || victim > MaxClients) return;

    for (int attacker = 1; attacker <= MaxClients; attacker++) {
        if (!IsClientInGame(attacker)) continue;

        for (int slot = 0; slot < 5; slot++) {
            if (g_iSlotVictim[attacker][slot] != victim) continue;

            int ent = EntRefToEntIndex(g_iSlotSpriteRef[attacker][slot]);
            if (ent > MaxClients && IsValidEntity(ent)) AcceptEntityInput(ent, "Kill");

            g_iSlotVictim[attacker][slot] = 0;
            g_iSlotSpriteRef[attacker][slot] = 0;
            g_fSlotLastDamage[attacker][slot] = 0.0;
        }
    }
}

public void Frame_HealthLogic(DataPack pack) {
    pack.Reset();
    int attackerUserId = pack.ReadCell();
    int attacker = GetClientOfUserId(attackerUserId);
    int victim = pack.ReadCell(); 
    int ticks = pack.ReadCell();
    int alpha = pack.ReadCell();
    int spriteRef = pack.ReadCell();
    int maxHP = pack.ReadCell();
    int slot = pack.ReadCell();
    
    int sprite = EntRefToEntIndex(spriteRef);

    // 1. Condição de término (Alpha baixo ou entidade inválida)
    if (sprite <= 0 || !IsValidEntity(sprite) || attacker <= 0 || !IsClientInGame(attacker) || alpha <= 5) {
        if (sprite > 0 && IsValidEntity(sprite)) AcceptEntityInput(sprite, "Kill");
        
        // Aplica o bloqueio de 10 segundos ao fechar a barra se a vítima morreu
        if (victim > 0 && victim < 2048 && IsValidEntity(victim) && IsVictimDyingOrDead(victim)) {
            BlockBarForVictim(victim, 10.0);
        }
        
        if (attacker > 0 && g_iSlotSpriteRef[attacker][slot] == spriteRef) {
            g_iSlotVictim[attacker][slot] = 0;
            g_iSlotSpriteRef[attacker][slot] = 0;
            g_fSlotLastDamage[attacker][slot] = 0.0;
        }
        delete pack; return;
    }

    if (g_iSlotSpriteRef[attacker][slot] != spriteRef) {
        delete pack; return;
    }

    ticks++;
    bool victimValid = false;
    int curHP = 0;
    bool isDying = true;
    bool isTank = false;

    // 2. Checagem de vida e estado (Dying Fix)
    if (victim > 0 && IsValidEntity(victim)) {
        curHP = GetEntProp(victim, Prop_Data, "m_iHealth");
        isDying = IsVictimDyingOrDead(victim);
        isTank = IsVictimTank(victim);
        if (!isDying && victim <= MaxClients && IsBarBlocked(victim)) isDying = true;

        if (curHP > 0 && !isDying) victimValid = true;
    }

    float vPos[3];
    if (victimValid) {
        // --- VÍTIMA VIVA: ATUALIZAÇÃO NORMAL ---
        GetEntPropVector(victim, Prop_Send, "m_vecOrigin", vPos);
        vPos[2] += BAR_HEIGHT;
        
        float pct = float(curHP) / float(maxHP);
        if (pct > 1.0) pct = 1.0;
        int frame = RoundToCeil(pct * 10.0);
        if (frame < 1 && curHP > 0) frame = 1; if (frame > 10) frame = 10;
        SetEntPropFloat(sprite, Prop_Data, "m_flFrame", float(frame));

        if (pct > 0.5) SetEntityRenderColor(sprite, 0, 255, 0, alpha);
        else if (pct > 0.2) SetEntityRenderColor(sprite, 255, 255, 0, alpha);
        else SetEntityRenderColor(sprite, 255, 0, 0, alpha);
        
        float linger = g_cvBarsLinger.FloatValue;
        if (linger < 0.0) linger = 0.0;

        float lastDmg = g_fSlotLastDamage[attacker][slot];
        if (lastDmg <= 0.0) lastDmg = GetGameTime();

        float age = GetGameTime() - lastDmg;
        if (age <= linger) alpha = 255;
        else alpha -= 10;
    } else {
        // --- MORTE: VAI PARA O PRETO (FRAME 0) E SOME FLUIDO ---
        if (isTank && isDying) {
            AcceptEntityInput(sprite, "Kill");
            if (attacker > 0 && g_iSlotSpriteRef[attacker][slot] == spriteRef) {
                g_iSlotVictim[attacker][slot] = 0;
                g_iSlotSpriteRef[attacker][slot] = 0;
                g_fSlotLastDamage[attacker][slot] = 0.0;
            }
            delete pack; return;
        }

        alpha -= 40; 
        SetEntPropFloat(sprite, Prop_Data, "m_flFrame", 0.0); // Mostra frame preto
        SetEntityRenderColor(sprite, 255, 255, 255, (alpha < 0 ? 0 : alpha)); // Remove filtro vermelho
        
        if (victim > 0 && IsValidEntity(victim)) {
            GetEntPropVector(victim, Prop_Send, "m_vecOrigin", vPos);
            vPos[2] += BAR_HEIGHT;
        } else {
            GetEntPropVector(sprite, Prop_Send, "m_vecOrigin", vPos);
        }
    }

    // 3. Posicionamento e Escala
    float vEyePos[3], vEyeAng[3], lookVec[3];
    GetClientEyePosition(attacker, vEyePos);
    GetClientEyeAngles(attacker, vEyeAng);
    MakeVectorFromPoints(vPos, vEyePos, lookVec);

    // Angulo mais estavel (evita flip quando o player esta muito acima/abaixo)
    float fullAng[3];
    GetVectorAngles(lookVec, fullAng);
    fullAng[0] *= -1.0;

    float yawVec[3];
    yawVec[0] = lookVec[0];
    yawVec[1] = lookVec[1];
    yawVec[2] = 0.0;

    float yawAng[3];
    float horiz = SquareRoot(yawVec[0] * yawVec[0] + yawVec[1] * yawVec[1]);
    float yaw = 0.0;
    if (horiz < 0.001) yaw = vEyeAng[1] + 180.0;
    else {
        GetVectorAngles(yawVec, yawAng);
        yaw = yawAng[1] + 180.0;
    }

    float pitch = fullAng[0];
    if (pitch > 80.0) pitch = 80.0;
    else if (pitch < -80.0) pitch = -80.0;

    float lookAng[3];
    lookAng[0] = pitch;
    lookAng[1] = yaw;
    lookAng[2] = 0.0;

    TeleportEntity(sprite, vPos, lookAng, NULL_VECTOR);

    float scale = (GetVectorDistance(vEyePos, vPos) / 500.0) * 0.22;
    if (scale < 0.08) scale = 0.08;
    float maxScale = g_cvBarsMaxScale.FloatValue;
    if (maxScale > 0.0 && scale > maxScale) scale = maxScale;
    SetVariantFloat(scale); AcceptEntityInput(sprite, "SetScale");

    pack.Reset();
    pack.WriteCell(attackerUserId); pack.WriteCell(victim); pack.WriteCell(ticks);
    pack.WriteCell(alpha); pack.WriteCell(spriteRef); pack.WriteCell(maxHP); pack.WriteCell(slot);
    RequestFrame(Frame_HealthLogic, pack);
}

public void Event_Damage(Event event, const char[] name, bool dontBroadcast) {
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int victim = (StrEqual(name, "player_hurt")) ? GetClientOfUserId(event.GetInt("userid")) : event.GetInt("entityid");

    if (attacker <= 0 || attacker > MaxClients || !IsClientInGame(attacker) || attacker == victim || !g_bState[attacker])
        return;
    if (GetClientTeam(attacker) != 2) return; // So sobrevivores veem barra

    if (victim <= 0 || victim >= 2048 || !IsValidEntity(victim)) return;
    if (victim <= MaxClients && GetClientTeam(victim) != 3) return; // Nunca mostra em sobrevivores/amigos
    if (victim <= MaxClients && GetClientTeam(attacker) == GetClientTeam(victim)) return;

    // Barra: nao mostra para dano de fogo (mas ainda corta/mata ao chegar em 0)
    int dmgType = event.GetInt("type");
    bool isFireDamage = (dmgType != 0 && ((dmgType & (DMG_BURN | DMG_SLOWBURN)) != 0));
    if (!isFireDamage) {
        char weapon[32];
        event.GetString("weapon", weapon, sizeof(weapon));
        if (weapon[0] != '\0') {
            if (StrContains(weapon, "inferno", false) != -1 ||
                StrContains(weapon, "molotov", false) != -1 ||
                StrContains(weapon, "fire", false) != -1 ||
                StrContains(weapon, "burn", false) != -1) {
                isFireDamage = true;
            }
        }
    }

    // Detecta o frame que a vida do Tank/SI chega a 0 (player_death pode vir so depois da animacao)
    if (StrEqual(name, "player_hurt") && victim > 0 && victim <= MaxClients) {
        int remainingHP = event.GetInt("health");
        if (remainingHP <= 0 || ShouldBlockTankDeathFromHurt(event, victim)) {
            BlockBarForVictim(victim, 15.0);
            KillBarsForVictim(victim);
            return;
        }
    }

    if (isFireDamage) return;

    if (IsVictimDyingOrDead(victim)) return;

    // Trava para não criar 10 timers para o MESMO zumbi (shotgun fix)
    float currentTime = GetGameTime();

    // Se a barra ja existe, so renova o tempo (nao recria timer/entidade)
    for (int i = 0; i < 5; i++) {
        if (g_iSlotVictim[attacker][i] != victim) continue;

        int ent = EntRefToEntIndex(g_iSlotSpriteRef[attacker][i]);
        if (ent != -1 && IsValidEntity(ent)) {
            g_fSlotLastDamage[attacker][i] = currentTime;
            return;
        }

        g_iSlotVictim[attacker][i] = 0;
        g_iSlotSpriteRef[attacker][i] = 0;
        g_fSlotLastDamage[attacker][i] = 0.0;
    }
    if (currentTime < g_fNextAllowedBar[attacker][victim]) return;
    g_fNextAllowedBar[attacker][victim] = currentTime + 0.12; 

    // RESERVA O SLOT AQUI (Resolve o problema de aparecer só um Common)
    if (!ConsumeBarToken(attacker)) return;

    int slot = g_iNextBarSlot[attacker];
    g_iNextBarSlot[attacker] = (slot + 1) % 5;

    g_fSlotLastDamage[attacker][slot] = currentTime;

    DataPack pack;
    CreateDataTimer(0.1, Timer_CreateBar, pack);
    pack.WriteCell(GetClientUserId(attacker));
    pack.WriteCell(victim);
    pack.WriteCell(slot); // Passa o slot reservado para o Timer
}

public Action Timer_CreateBar(Handle timer, DataPack pack) {
    pack.Reset();
    int attackerUserId = pack.ReadCell();
    int attacker = GetClientOfUserId(attackerUserId);
    int victim = pack.ReadCell();
    int slot = pack.ReadCell();

    if (attacker <= 0 || !IsClientInGame(attacker) || !IsValidEntity(victim)) return Plugin_Stop;

    // Bloqueia a criação se o bicho estiver nos 10 segundos de "morte"
    if (IsBarBlocked(victim)) return Plugin_Stop;
    if (IsVictimDyingOrDead(victim)) return Plugin_Stop;

    // Se já existe barra ativa para esse bicho, não cria outra
    for (int i = 0; i < 5; i++) {
        if (g_iSlotVictim[attacker][i] == victim) {
            int check = EntRefToEntIndex(g_iSlotSpriteRef[attacker][i]);
            if (check != -1 && IsValidEntity(check)) {
                g_fSlotLastDamage[attacker][i] = GetGameTime();
                return Plugin_Stop;
            }

            g_iSlotVictim[attacker][i] = 0;
            g_iSlotSpriteRef[attacker][i] = 0;
            g_fSlotLastDamage[attacker][i] = 0.0;
        }
    }

    int oldEnt = EntRefToEntIndex(g_iSlotSpriteRef[attacker][slot]);
    if (oldEnt > MaxClients && IsValidEntity(oldEnt)) AcceptEntityInput(oldEnt, "Kill");

    int maxHP = GetEntProp(victim, Prop_Data, "m_iMaxHealth");
    if (maxHP <= 1) {
        char cls[64]; GetEntityClassname(victim, cls, sizeof(cls));
        if (StrEqual(cls, "infected")) maxHP = 50;
        else if (StrEqual(cls, "witch")) maxHP = 1000;
        else maxHP = GetEntProp(victim, Prop_Data, "m_iHealth");
    }
    if (maxHP <= 0) maxHP = 100;

    // Em SI (principalmente Tank), m_iMaxHealth pode vir errado (ex: 100). Garante base correta.
    if (HasEntProp(victim, Prop_Data, "m_iHealth")) {
        int curHP = GetEntProp(victim, Prop_Data, "m_iHealth");
        if (curHP > maxHP) maxHP = curHP;
    }

    int sprite = CreateEntityByName("env_sprite_oriented");
    if (sprite == -1) return Plugin_Stop;

    ge_iOwner[sprite] = attacker;
    SetEdictFlags(sprite, GetEdictFlags(sprite) & ~FL_EDICT_ALWAYS);
    DispatchKeyValue(sprite, "model", g_sBarPath);
    DispatchKeyValue(sprite, "rendermode", "1");
    DispatchSpawn(sprite);
    SDKHook(sprite, SDKHook_SetTransmit, OnTransmit);

    int spriteRef = EntIndexToEntRef(sprite);
    g_iSlotSpriteRef[attacker][slot] = spriteRef;
    g_iSlotVictim[attacker][slot] = victim;
    g_fSlotLastDamage[attacker][slot] = GetGameTime();

    DataPack fPack = new DataPack();
    fPack.WriteCell(attackerUserId);
    fPack.WriteCell(victim);
    fPack.WriteCell(0); fPack.WriteCell(255);
    fPack.WriteCell(spriteRef);
    fPack.WriteCell(maxHP);
    fPack.WriteCell(slot);
    RequestFrame(Frame_HealthLogic, fPack);

    return Plugin_Stop;
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (victim <= 0 || victim > MaxClients || !IsValidEntity(victim)) return;

    // Bloqueia barras para esse mesmo player durante a animacao de morte
    BlockBarForVictim(victim, 15.0);

    // Mata barras existentes imediatamente (principalmente Tank)
    KillBarsForVictim(victim);
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || client > MaxClients) return;

    g_iBlockBarRef[client] = 0;
    g_fBlockBarUntil[client] = 0.0;
    g_fBlockBar[client] = 0.0;
    g_iTankRef[client] = 0;
    g_iTankHP[client] = 0;
}
