module Discord::CcMentions
    extend self

    module Roles
        extend self

        def admin
            "<@&174838443111612417>"
        end
    
        def dev
            "<@&174846441678700544>"
        end
    
        def designer
            "<@&174851151953526785>"
        end
    
        def partner
            "<@&753617177730613378>"
        end
    
        def sr_mod
            "<@&709042556335292437>"
        end
    
        def mod
            "<@&174838794665590784>"
        end
    
        def java
            "<@&778709973373812737>"
        end
    
        def bedrock
            "<@&778709999081619486>"
        end
    
        def updates
            "<@&925407712861360198>"
        end
    
        def events
            "<@&942424800901599303>"
        end

        def changelog
            "<@&930111883560755250>"
        end

        def testing
            "<@&1128696048781623308>"
        end
    end

    module Channels
        extend self

        def announcements
            "<#206325275733131264>"
        end

        def changelog
            "<#753581142203957309>"
        end

        def general
            "<#174837853778345984>"
        end

        def help
            "<#1019248948449378404>"
        end
    end
end