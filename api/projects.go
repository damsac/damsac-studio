package main

import (
	"html/template"
	"log"
	"net/http"
)

// ProjectsHandler serves the projects page.
type ProjectsHandler struct {
	tmpl        *template.Template
	githubToken string
}

type projectsPageData struct {
	Title      string
	InProgress []ProjectItem
	Todo       []ProjectItem
	Backlog    []ProjectItem
	Done       int
	Total      int
	Error      string
}

func (p *ProjectsHandler) HandleProjects(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	if p.githubToken == "" {
		p.render(w, projectsPageData{Error: "GITHUB_TOKEN not configured"})
		return
	}

	project, err := FetchProject(p.githubToken, "damsac", 2)
	if err != nil {
		log.Printf("projects: fetch: %v", err)
		p.render(w, projectsPageData{Error: "Failed to fetch project data"})
		return
	}

	data := projectsPageData{
		Title: project.Title,
		Total: len(project.Items),
	}

	for _, item := range project.Items {
		switch item.Status {
		case "In Progress":
			data.InProgress = append(data.InProgress, item)
		case "Todo":
			data.Todo = append(data.Todo, item)
		case "Backlog":
			data.Backlog = append(data.Backlog, item)
		case "Done":
			data.Done++
		}
	}

	p.render(w, data)
}

func (p *ProjectsHandler) getTemplate() *template.Template {
	if devMode {
		t, err := template.ParseFiles(
			"templates/layout.html",
			"templates/projects.html",
		)
		if err != nil {
			log.Printf("projects: dev parse templates: %v", err)
			return p.tmpl
		}
		return t
	}
	return p.tmpl
}

func (p *ProjectsHandler) render(w http.ResponseWriter, data projectsPageData) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := p.getTemplate().ExecuteTemplate(w, "layout.html", data); err != nil {
		log.Printf("projects: render: %v", err)
	}
}
