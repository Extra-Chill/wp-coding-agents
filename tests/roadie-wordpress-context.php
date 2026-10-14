<?php
// Boundary fixture: registry layer selection and explicit user scoping. A
// live read against the installed WordPress follows before local activation.
namespace DataMachine\Engine\AI {
    class MemoryFileRegistry {
        const MODE_ALL='all', INJECTION_AGENT_IDENTITY='identity', INJECTION_AGENT_MEMORY='memory', INJECTION_USER_PROFILE='user', LAYER_AGENT='agent', LAYER_USER='user', LAYER_PRINCIPAL='principal';
        public static function get_for_modes($modes,$contexts) { return array('SOUL.md'=>array('layer'=>'agent','priority'=>10,'convention_path'=>''),'AGENTS.md'=>array('layer'=>'shared','priority'=>12,'convention_path'=>'AGENTS.md'),'USER.md'=>array('layer'=>'user','priority'=>25),'USER_MEMORY.md'=>array('layer'=>'principal','priority'=>28)); }
    }
}
namespace DataMachine\Core\FilesRepository {
    class AgentMemory {
        public function __construct(public int $user,public int $agent,public string $file,public string $layer) {}
        public function get_all() { return array('success'=>true,'content'=>$this->layer.':'.$this->user.':'.$this->file); }
    }
}
namespace DataMachine\Core\Agents {
    class AgentIdentityResolver { public function resolve_agent_identity($slug) { return (object) array('owner_id'=>1); } }
}
namespace DataMachine\Core\Database\Agents {
    class AgentAccess {
        // Grants: 3 viewer, 4 operator, 5 admin. Mirrors the role hierarchy.
        public function user_can_access($agent_id,$user_id,$role) {
            $grants=array(3=>'viewer',4=>'operator',5=>'admin'); $rank=array('viewer'=>1,'operator'=>2,'admin'=>3);
            return $agent_id===7 && isset($grants[$user_id]) && $rank[$grants[$user_id]]>=$rank[$role];
        }
    }
}
namespace {
    class WP_Agent { public function get_meta() { return array('datamachine_agent_id'=>7); } }
    function wp_get_agent($slug) { return new WP_Agent(); }
    function get_user_by($field,$id) { return in_array($id,array(1,2,3,4,5,6,7),true) ? (object) array('ID'=>$id) : false; }
    function user_can($user,$cap) { return $user->ID===2; }
    // User 6 is admitted only by the host access filter (a team entitlement).
    function apply_filters($name,$value,...$args) { return $name==='datamachine_can_access_agent' && $args[1]===6 && $args[2]==='viewer' ? true : $value; }
    function wp_json_encode($value) { return json_encode($value); }
    function resolve_context($request) {
        $args=array(base64_encode(json_encode($request)));
        ob_start(); include __DIR__.'/../bridges/roadie/roadie-plugins/wordpress-context.php'; return json_decode(ob_get_clean(),true);
    }
    $base=array('operation'=>'context','agent_slug'=>'franklin');
    $shared=resolve_context($base+array('event'=>'session_start','user_id'=>1));
    if (array_column($shared['sections'],'content')!==array('agent:0:SOUL.md','shared:0:AGENTS.md')) throw new \RuntimeException('Pinned context contains user memory');
    // #733: convention files carry their path so the plugin can skip what the runtime loads from disk.
    if (array_key_exists('convention_path',$shared['sections'][0])||($shared['sections'][1]['convention_path']??null)!=='AGENTS.md') throw new \RuntimeException('convention_path not passed through');
    foreach (array(1,2,3) as $id) {
        $turn=resolve_context($base+array('event'=>'turn','user_id'=>$id));
        $content=array_column($turn['sections'],'content');
        if (!in_array('user:'.$id.':USER.md',$content,true)||!in_array('principal:'.$id.':USER_MEMORY.md',$content,true)||in_array('agent:0:SOUL.md',$content,true)||in_array('shared:0:AGENTS.md',$content,true)) throw new \RuntimeException('Wrong speaker/layer');
    }
    if(resolve_context($base+array('event'=>'turn','user_id'=>999))['sections']!==array()) throw new \RuntimeException('Unknown user inherited owner context');
    // #711 seat tier: owner and administrators are admin, otherwise the grant role;
    // filter-only admission is viewer; no access or an unknown user is denied with no role.
    $expected=array(1=>array(true,'admin'),2=>array(true,'admin'),3=>array(true,'viewer'),4=>array(true,'operator'),5=>array(true,'admin'),6=>array(true,'viewer'),7=>array(false,''),999=>array(false,''));
    foreach ($expected as $id=>$want) {
        $person=resolve_context(array('operation'=>'person','agent_slug'=>'franklin','user_id'=>$id));
        if (array($person['allowed'],$person['role'])!==$want) throw new \RuntimeException('Wrong seat for user '.$id.': '.json_encode($person));
    }
    echo "PASS: shared/user/principal memory separation, missing-user rejection, seat role from agent access\n";
}
