module Docker = Current_docker.Default
module Slack = Current_slack
module Images = Map.Make (String)

let default_worker = "autumn"
let default_docker = "ocaml/opam:debian-11-ocaml-4.13"

type repo = {
  name : string;
  worker : string; [@default default_worker]
  image : string; [@default default_docker]
}
[@@deriving yojson]

type repo_list = repo list [@@deriving yojson]
type api_token = { repo : string; token : string } [@@deriving yojson]
type api_token_list = api_token list [@@deriving yojson]

type config = {
  repositories : repo_list;
  api_tokens : api_token_list;
  slack : (string option[@default None]);
}
[@@deriving yojson]

type t = {
  repos : repo_list;
  images : Docker.Image.t Current.t Images.t;
  api_tokens : api_token_list;
  slack : Slack.channel option;
  frontend_url : string;
  pipeline_url : string;
}

let weekly = Current_cache.Schedule.v ~valid_for:(Duration.of_day 7) ()

let pull img images =
  if Images.mem img images
  then images
  else
    let docker = Docker.pull ~schedule:weekly img in
    Images.add img docker images

let make_images repos =
  List.fold_left
    (fun acc repo ->
      let img = repo.image in
      pull img acc)
    (pull default_docker Images.empty)
    repos

let slack_of_url = function
  | None -> None
  | Some url -> Some (Slack.channel (Uri.of_string url))

let of_file ~frontend_url ~pipeline_url filename : t =
  let filename = Fpath.to_string filename in
  let json = Yojson.Safe.from_file filename in
  match config_of_yojson json with
  | Ok { repositories; api_tokens; slack } ->
      {
        repos = repositories;
        api_tokens;
        images = make_images repositories;
        slack = slack_of_url slack;
        frontend_url;
        pipeline_url;
      }
  | Error err -> failwith (Printf.sprintf "Config.of_file %S : %s" filename err)

let find t name =
  match List.filter (fun r -> r.name = name) t.repos with
  | [] -> [ { name; worker = default_worker; image = default_docker } ]
  | configs -> configs

let find_image t image_name = Images.find image_name t.images

let repo_url ~config repo worker docker_image =
  Printf.sprintf "%s/%s?worker=%s&image=%s" config.frontend_url
    (Repository.to_path repo) (Uri.pct_encode worker)
    (Uri.pct_encode docker_image)

let job_url ~config job_id start stop =
  Printf.sprintf "%s/job/%s#L%i-L%i" config.pipeline_url job_id start stop

let key_of_repo ~config repository worker docker_image =
  Printf.sprintf "<%s|*%s* _%s_ %s>"
    (repo_url ~config repository worker docker_image)
    (Repository.to_string repository)
    worker docker_image

let slack_log ~config ~key msg =
  match config.slack with
  | None -> Current.ignore_value msg
  | Some channel ->
      Logs.err (fun log -> log "slack_post? %s" key);
      let msg =
        let open Current.Syntax in
        let+ state = Current.catch ~hidden:true msg in
        let icon, msg =
          match state with
          | Ok msg -> (":heavy_check_mark:", msg)
          | Error (`Msg e) -> (":x: <!here>", "*`" ^ e ^ "`*")
        in
        icon ^ " " ^ key ^ ": " ^ msg
      in
      Slack.post channel ~key msg
