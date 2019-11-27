#!/usr/bin/env perl

use strict;
use Socket;
use POSIX q(setsid);

# Устанавливаем порт на котором будем слушать
my $p=$ARGV[0]+0; # Берём первый аргумент скрипта и делаем его числом
$p=$p?$p:16669;   # Если число ноль, то пусть порт будет 16669

my $e="\r\n";        # Запоминаем, чем должны заканчиваться строки передаваемые нам телнетом
my $q=$e.q(quit).$e; # Определяем строку quit, с которой будем сравнивать пользовательский ввод

# Создаём слушающий сокет S
socket(S,PF_INET,SOCK_STREAM,getprotobyname(q(tcp)));
setsockopt(S,SOL_SOCKET,SO_REUSEADDR,1); # Говорим, что будем использовать его многократно/впаралель

# Ставим таймаут 5 секунд, хотя это можно и не делать. Просто, так работа скрипта будет нагляднее
setsockopt(S,SOL_SOCKET,SO_RCVTIMEO,pack(q(l!l!), 5, 0));

# Подключаем наш слушающий порт p на все сетевые интерфейсы
bind(S,sockaddr_in($p,INADDR_ANY));
listen(S,50);

# Работаем бесконечно, пока нас кто-нибудь не прибъёт
while(1){
    # Ждём входящего соединения типа: $telnet localhost 16669
    if( accept(X,S) ){
        # ОК, кто-то подключился
        # Создаём трубу из двух файловых дескрипторов W (Writer) в R (Reader)
        pipe R, W;
        # В W мы будем писать перехваченный из сокета пользовательский ввод
        W->autoflush; # Поэтому делаем автосброс буферов по концам строк
        # Так нам будет проще понимать скрипт

        # Форкаемся на два процесса
        if(!(my $p=fork)){ # В лакальную переменную p получаем PIDы процессов

            # p==0 Это форкнутый процесс потомок, в котором будет жить шелл-сессия
            print "Shell: $$ p=$p\n"; # Докажем это пользователю консоли, показав новый текущий PID=$$

            setsid; # создаём сессию и ставим  process group ID как у родителя

            # Открываем стандатрные дескрипторы на наши потоки
            open STDIN,q(<&R); # Читать ввод в шел сессию будем из открытой ранее трубы (pipe R, что-то;)
            open STDOUT,q(>&X); open STDERR,q(>&X); # Вывод шел сессии будем напрямую слать телнету

            exec(q(/bin/sh -i)); # запустили интерактивный обрезанный шелл без job control
            # Он будет работать пока или сам не сделает выход или ему сверху не просигналят например HUP
            # т.е. обрезав канал STDIN ( кстати, только ли на оборванный STDIN SIGHUP случается?)

            close X; # Если мы еще живы (сам пользователь дал exit), то закрываем дескриптор
            # Здесь могла бы быть функция exit; но смысла в ней нет. Всё и так случится по SIGHUP

            # Всё, данный потомок мёртв. Можете убетилтся посмотрев ps

        }else{
            # p!=0 Это наш продолжающийся основной процесс с бесконечным циклом
            print "Parent: $$ p=$p\n";  # Докажем это пользователю консоли,
                                        # показав старый PID=$$ и p -отпрыска, что выше

            # Форкаемся ещё раз, поскольку нам нужен живой процесс, чтобы перехватывать
            # и анализировать ввод из телнета
            if(!(my $l=fork)){
                # Это наш форкнутый потомок, как в примере выше
                setsid;
                STDOUT->autoflush; # Это чтобы в консоли скрипта видеть всё происходящее вживую

                print "\tDispatch: $$ l=$l X=".fileno(X)."\n"; # Показываем как форкнулиь и как утекают дескипторы

                # Определим переменные $b - скользящий буфер, пока как просто \r\n
                my ($b,$r,$c)=($e);  # и неопределённые пока $r - для чтения сокета и $c - счётчик прочитанных байт

                # Цикл длинного и нудного чтения всего что ввёл в телнете пользователь
                # пока жив X открытый в верхнем while(1){ if( accept(X,S) ...
                # и пока счётчик байт возвразает или число прочитанного
                #                                или undef, если пользователь молчит, а TCP тайм-аут случился
                while(defined fileno(X) && $c ne q(0) ){

                    print "... "; # показываем в консоль, что что-то всё-таки происходит

                    if($c=X->sysread($r,10000)){ # Читаем в буфер $r что-то из телнета

                        # счётчик $c и не undef и не ноль
                        #
                        $b.=$r; # дополним буфер прочитанным
                        $b=substr($b,-length($q)); # обрежем буфер до длинны равной длине "\r\nquit\r\n"
                                                   # т.е. оставим буфер ровно в его последние восемь байт

                        if($b eq $q){ # сравним ввод пользователя с предопределённой строкой quit
                            # да, нужен выход
                            # закрываем дескриптор сокета в который пишет тот верхний чайлд, который шелл
                            close X;
                        }
                        else{
                            # нет не quit. Просто скармливаем шелу, весь полученный из sysread ввод
                            print W $r; # Печатем в наш pipe - writtеr и верхний чайл с шеллом его получит
                        }
                    } # закончили чтение или ожидание ввода из телнета
                }
                # Больше из сокета ничего уже не читается
                # Закроем нашу трубу pipe(R,W) со стороны writer
                close W;

                kill q(HUP), $p; # Отправим в верхний чайлд с шеллом сигнал, что всё - можно умирать

                print "HERE $$ !\n"; # Покажем пользователю, что всё кончено

                exit; # заканчиваем работу нашего фокнутого потомка, который прехватывал ввод в теленет

            }else{
                # Это не форкнутый потомок, а всё тот же наш основной процесс
                print "\tParent: $$ l=$l\n";
                # Закроем почти все скобки и перейдем в начало while(1){ if( accept(X,S) ...
                # чтобы позволить нашему скрипту принимать паралелльные соединения от других телнетов
            }
        }
    }
}
                  
__END__
