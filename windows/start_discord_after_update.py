
import os
os.system("choco install discord.install discord -y --force")
path = os.getenv('LOCALAPPDATA')+"\\Discord"
target = []
for x in os.listdir(path):
	if x.startswith('app-'):
		target.append(x)

target.sort()
os.system(path+"\\"+target[-1]+"\\Discord.exe --squirrel-firstrun")
