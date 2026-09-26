@echo off
cd /d C:\mtserver\MotorTown\Binaries\Win64
MotorTownServer-Win64-Shipping.exe Jeju_World?listen? -server -log -useperfthreads -Port=7778 -QueryPort=27016 -externalip=49.0.82.49 -MultiHome=0.0.0.0 -norestart -nullrhi
