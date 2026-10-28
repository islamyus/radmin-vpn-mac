#!/bin/zsh
cd "${0:A:h}" || exit 1
./radmin-network-test --interactive
RESULT=$?
print ""
if (( RESULT == 2 )); then
    print "Данные дошли, но есть потери или задержки UDP. Подробности — в отчёте."
elif (( RESULT != 0 )); then
    print "Есть ошибки: посмотрите сообщение выше и отчёт в папке Reports."
fi
read -r "REPLY?Нажмите Enter, чтобы закрыть окно. "
exit "$RESULT"
