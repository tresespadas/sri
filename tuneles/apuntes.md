# Crear una carperta compartida (sshfs) en Windows:
# Explorador > Botón derecho en red > \\sshfs\usuario-de-linux@ip-apertura-tunel!puerto-apertura/carpeta-a-compartir
# NOTA: / ya se encuentra en el /home/usuario

# Usar PSCP.EXE en Windows:
C:\TOOLS\putty>PSCP.EXE -P 9040 "C:\Users\omar\Documents\examen.txt" root@ip-apertura-tunel:/home/usuario/
